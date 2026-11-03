import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// EXPERIMENTAL direct BLE lane for the Garmin CIRQA Smart Band (screenless band, no subscription).
///
/// Phase 1 (this file): connect over the band's multi-link service, run the GFDI handshake, stream live
/// heart rate through the realtime-HR handle, and LIST the band's stored files (a read-only directory
/// download), logging each step. It never archives, deletes or writes a file, so the band's history stays
/// where it is for the next phase (and for Garmin Connect if the user re-pairs it there).
///
/// Isolation: its OWN `CBCentralManager`, no reference to `BLEManager`, so the WHOOP path cannot regress.
/// Shared surfaces are `LiveState` (live HR on the Live/Today screens) and `persist` (HR samples into the
/// store under this device's id, exactly like `StandardHRSource`). Every protocol byte lives in the pure
/// `GarminGFDI` codec (WhoopProtocol), covered by `GarminGFDITests`.
@MainActor
public final class GarminCirqaSource: NSObject, ObservableObject {

    /// A band seen during a scan (same shape the wizard's strap list already renders).
    public typealias DiscoveredBand = StandardHRSource.DiscoveredStrap

    @Published public private(set) var discovered: [DiscoveredBand] = []
    @Published public private(set) var scanning = false

    /// True for a registry `model` / advertised name this lane drives.
    public nonisolated static func isCirqa(name: String?) -> Bool {
        (name ?? "").localizedCaseInsensitiveContains("cirqa")
    }

    private static let mlService = CBUUID(string: GarminGFDI.multiLinkService)
    private static let stdHRService = CBUUID(string: "180D")
    private static let stdHRMeasurement = CBUUID(string: "2A37")

    // MARK: - Dependencies

    private let live: LiveState
    private let deviceId: String
    private let persist: (Streams) -> Void
    private let log: (String) -> Void
    /// False for the wizard's discovery-only scanner: never touches LiveState or the store.
    private let feedsLive: Bool

    // MARK: - CoreBluetooth state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    // MARK: - Multi-link / GFDI session state

    private var handles: [UInt16: UInt8] = [:]          // service code → handle
    private var gfdiAssembler = GarminGFDI.CobsAssembler()
    private var maxPacketSize = 375
    private var handshakeDone = false
    private var loggedFirstHR = false
    /// Consecutive pairing refusals ("encryption insufficient"): the band wants a bonded link first. Each one
    /// pushes the next reconnect further out so iOS has room to run its pairing prompt.
    private var encryptionFailures = 0

    /// The in-flight directory download (index 0), if any.
    private struct Download {
        var size: Int
        var data: [UInt8] = []
        var crc: UInt16 = 0
    }
    private var download: Download?

    // MARK: - Sample buffer (same batching as StandardHRSource)

    private var buffer: [(hr: Int, rr: [Int], ts: Int)] = []
    /// True once the standard 0x2A37 stream delivers; the multi-link realtime-HR copy is then ignored.
    private var standardHRFlowing = false
    private var lastFlush = Date()

    public init(live: LiveState,
                deviceId: String,
                persist: @escaping (Streams) -> Void,
                log: @escaping (String) -> Void = { _ in },
                feedsLive: Bool = true) {
        self.live = live
        self.deviceId = deviceId
        self.persist = persist
        self.log = log
        self.feedsLive = feedsLive
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scan / connect / stop

    /// Scan for CIRQA bands. The band may not advertise the multi-link service, so this scans everything
    /// and keeps only peripherals whose name says CIRQA (or that advertise the multi-link service).
    public func scan() {
        discovered.removeAll()
        scanning = true
        log("Garmin: scanning for a CIRQA band…")
        guard central.state == .poweredOn else {
            log("Garmin: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred")
            return
        }
        // A band already connected to this iPhone (paired in Settings, or held by another app) stops
        // advertising, so a scan alone never sees it: list the system-connected ones too.
        // Name-filtered: iOS can hand back unrelated connected peripherals here (a WHOOP was listed once).
        for p in central.retrieveConnectedPeripherals(withServices: [Self.mlService]) where Self.isCirqa(name: p.name) {
            log("Garmin: found \(LiveState.logSafeDeviceName(p.name ?? "Garmin")) already connected to the system")
            seenPeripherals[p.identifier] = p
            discovered = StandardHRSource.upsertByProximity(
                discovered, DiscoveredBand(id: p.identifier, name: p.name ?? "CIRQA Smart Band", rssi: -50))
        }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    public func connect(_ id: UUID) {
        stopScan()
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Garmin: connect deferred - Bluetooth not powered on")
            return
        }
        guard let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            pendingConnectID = id
            log("Garmin: band \(id) not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        log("Garmin: connecting to \(id)")
        central.connect(p, options: nil)
    }

    public func stop() {
        stopScan()
        pendingConnectID = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        resetSession()
        flush()
        if feedsLive { live.connected = false }
    }

    private func resetSession() {
        notifyChar = nil
        writeChar = nil
        handles.removeAll()
        gfdiAssembler.reset()
        handshakeDone = false
        loggedFirstHR = false
        standardHRFlowing = false
        download = nil
    }

    // MARK: - Writing

    private func writeRaw(_ bytes: [UInt8]) {
        guard let p = peripheral, let ch = writeChar else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    /// Send one GFDI message on the GFDI handle (COBS-wrapped, chunked to the link's write size).
    private func sendGFDI(_ message: [UInt8], _ label: String) {
        guard let p = peripheral, let ch = writeChar, let handle = handles[GarminGFDI.Service.gfdi.rawValue] else {
            log("Garmin: cannot send \(label) - GFDI handle not registered")
            return
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        let maxWrite = min(p.maximumWriteValueLength(for: type), 512)
        for chunk in GarminGFDI.chunks(GarminGFDI.cobsEncode(message), handle: handle, maxWrite: maxWrite) {
            p.writeValue(Data(chunk), for: ch, type: type)
        }
        log("Garmin: → \(label)")
    }

    // MARK: - Inbound routing

    private func handleNotify(_ v: [UInt8]) {
        guard let handle = v.first else { return }
        if handle == 0 {
            handleManagement(v)
            return
        }
        if handle & 0x80 != 0 {
            log("Garmin: MLR (reliable) packet on handle \((handle & 0x70) >> 4) - not supported in this build, dropped")
            return
        }
        let body = Array(v.dropFirst())
        if handle == handles[GarminGFDI.Service.gfdi.rawValue] {
            for frame in gfdiAssembler.feed(body) {
                guard let msg = GarminGFDI.parse(frame) else {
                    log("Garmin: GFDI frame failed length/CRC check (\(frame.count) bytes) - dropped")
                    continue
                }
                handleGFDI(msg)
            }
        } else if handle == handles[GarminGFDI.Service.realtimeHR.rawValue] {
            handleRealtimeHR(body)
        } else {
            log("Garmin: \(v.count) bytes on unknown handle \(handle)")
        }
    }

    private func handleManagement(_ v: [UInt8]) {
        guard let event = GarminGFDI.parseHandleMessage(v) else {
            log("Garmin: handle-0 message not for us (\(v.count) bytes)")
            return
        }
        switch event {
        case .closeAllDone:
            handles.removeAll()
            log("Garmin: multi-link reset - registering GFDI and realtime HR")
            writeRaw(GarminGFDI.registerRequest(.gfdi))
            writeRaw(GarminGFDI.registerRequest(.realtimeHR))
        case let .registered(service, status, handle, reliable):
            guard status == 0 else {
                log("Garmin: band refused service \(service) (status \(status))")
                return
            }
            handles[service] = handle
            log("Garmin: service \(service) on handle \(handle)\(reliable ? " (band asked for MLR)" : "")")
        case let .closed(service, handle):
            handles[service] = nil
            log("Garmin: band closed service \(service) (handle \(handle))")
            if service == GarminGFDI.Service.gfdi.rawValue { writeRaw(GarminGFDI.registerRequest(.gfdi)) }
        case let .other(type):
            log("Garmin: handle-0 message type \(type) ignored")
        }
    }

    private func handleGFDI(_ msg: GarminGFDI.Message) {
        typealias Id = GarminGFDI.MessageId
        switch msg.id {
        case Id.deviceInformation.rawValue:
            guard let info = GarminGFDI.parseDeviceInformation(msg.payload) else {
                log("Garmin: DEVICE_INFORMATION unreadable")
                return
            }
            maxPacketSize = Int(info.maxPacketSize)
            log("Garmin: band \(info.deviceName) product=\(info.productNumber) software=\(info.softwareVersionString) protocol=\(info.protocolVersion) maxPacket=\(info.maxPacketSize)")
            sendGFDI(GarminGFDI.deviceInformationReply(to: info, hostName: "NOOP", manufacturer: "Apple",
                                                       device: "iPhone"), "DEVICE_INFORMATION reply")
        case Id.configuration.rawValue:
            let caps = GarminGFDI.parseConfiguration(msg.payload) ?? []
            log("Garmin: band capabilities (\(caps.count) bytes)")
            sendGFDI(GarminGFDI.response(to: msg.id), "CONFIGURATION ack")
            sendGFDI(GarminGFDI.configurationMessage(), "CONFIGURATION")
            completeHandshake()
        case Id.currentTimeRequest.rawValue:
            if let reply = GarminGFDI.currentTimeReply(requestPayload: msg.payload, now: Date(), timeZone: .current) {
                sendGFDI(reply, "CURRENT_TIME reply")
            }
        case Id.synchronization.rawValue:
            sendGFDI(GarminGFDI.response(to: msg.id), "SYNCHRONIZATION ack")
            sendGFDI(GarminGFDI.filterOnlyNew(), "FILTER (only new)")
        case Id.response.rawValue:
            handleResponse(msg.payload)
        case Id.fileTransferData.rawValue:
            handleFileChunk(msg.payload)
        default:
            log("Garmin: message \(msg.id) (\(msg.payload.count) bytes) - acknowledged, not decoded")
            sendGFDI(GarminGFDI.response(to: msg.id), "ack \(msg.id)")
        }
    }

    /// After the configuration exchange: tell the band we're ready, finish first-time setup once, then list
    /// its files.
    private func completeHandshake() {
        guard !handshakeDone else { return }
        handshakeDone = true
        if feedsLive { live.connected = true }
        let setupKey = "garminCirqaSetupDone.\(deviceId)"
        if !UserDefaults.standard.bool(forKey: setupKey) {
            sendGFDI(GarminGFDI.systemEvent(.pairComplete), "PAIR_COMPLETE")
            sendGFDI(GarminGFDI.systemEvent(.syncComplete), "SYNC_COMPLETE")
            sendGFDI(GarminGFDI.systemEvent(.setupWizardComplete), "SETUP_WIZARD_COMPLETE")
            UserDefaults.standard.set(true, forKey: setupKey)
        }
        sendGFDI(GarminGFDI.systemEvent(.syncReady), "SYNC_READY")
        guard feedsLive else { return }
        download = nil
        sendGFDI(GarminGFDI.downloadRequest(index: 0), "DOWNLOAD_REQUEST directory")
    }

    private func handleResponse(_ p: [UInt8]) {
        guard p.count >= 3 else { return }
        let original = UInt16(p[0]) | UInt16(p[1]) << 8
        if original == GarminGFDI.MessageId.downloadRequest.rawValue {
            guard let st = GarminGFDI.parseDownloadStatus(p) else { return }
            if st.canProceed, let size = st.fileSize {
                download = Download(size: Int(size))
                log("Garmin: directory download accepted - \(size) bytes")
            } else {
                log("Garmin: directory download refused (status \(st.status), download status \(st.downloadStatus.map { "\($0)" } ?? "-"))")
            }
        } else if p[2] != GarminGFDI.Status.ack.rawValue {
            log("Garmin: band answered \(original) with status \(p[2])")
        }
    }

    private func handleFileChunk(_ p: [UInt8]) {
        guard var d = download, let chunk = GarminGFDI.parseFileChunk(p) else {
            log("Garmin: file data with no download in progress - ignored")
            return
        }
        guard Int(chunk.offset) == d.data.count else {
            log("Garmin: file chunk at offset \(chunk.offset), expected \(d.data.count) - aborting")
            download = nil
            return
        }
        let crc = GarminGFDI.crc16(chunk.data, seed: d.crc)
        guard crc == chunk.crc else {
            log("Garmin: file chunk CRC mismatch at offset \(chunk.offset) - aborting")
            download = nil
            return
        }
        d.crc = crc
        d.data += chunk.data
        sendGFDI(GarminGFDI.fileChunkAck(nextOffset: UInt32(d.data.count)), "file ack \(d.data.count)/\(d.size)")
        if d.data.count >= d.size {
            download = nil
            logDirectory(d.data)
        } else {
            download = d
        }
    }

    private func logDirectory(_ data: [UInt8]) {
        let entries = GarminGFDI.parseDirectory(data)
        log("Garmin: directory has \(entries.count) file(s)")
        let df = ISO8601DateFormatter()
        var counts: [String: Int] = [:]
        for e in entries { counts[e.kindName, default: 0] += 1 }
        log("Garmin: by kind: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        for e in entries.suffix(40) {
            let when = e.unixTimestamp.map { df.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? "-"
            log("Garmin:   #\(e.index) \(e.kindName) size=\(e.size) flags=\(e.flags) at \(when)")
        }
    }

    private func handleRealtimeHR(_ body: [UInt8]) {
        guard !standardHRFlowing, let r = GarminGFDI.parseRealtimeHR(body) else { return }
        if !loggedFirstHR {
            loggedFirstHR = true
            log("Garmin: live heart rate flowing (multi-link) - first sample \(r.hr) bpm (resting \(r.resting))")
        }
        ingest(hr: r.hr, rr: [])
    }

    /// Standard 0x2A37 Heart Rate Measurement (with RR intervals when the band includes them).
    private func handleStandardHR(_ bytes: [UInt8]) {
        guard let m = StandardHeartRate.parse(bytes), m.hr > 0 else { return }
        if !standardHRFlowing {
            standardHRFlowing = true
            log("Garmin: live heart rate flowing (standard 0x2A37) - first sample \(m.hr) bpm, rr=\(m.rr.count)")
        }
        ingest(hr: m.hr, rr: m.rr)
    }

    private func ingest(hr: Int, rr: [Int]) {
        guard feedsLive else { return }
        live.heartRate = hr
        live.connected = true
        buffer.append((hr: hr, rr: rr, ts: Int(Date().timeIntervalSince1970)))
        if buffer.count >= 30 || Date().timeIntervalSince(lastFlush) >= 30 { flush() }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        for s in buffer { persist(StandardHRMapping.samples(fromHR: s.hr, rr: s.rr, at: s.ts)) }
        buffer.removeAll()
        lastFlush = Date()
    }
}

// MARK: - CBCentralManagerDelegate

extension GarminCirqaSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if feedsLive { live.connected = false }
            return
        }
        if let id = pendingConnectID {
            pendingConnectID = nil
            connect(id)
        } else if feedsLive, let p = peripheral, p.state == .disconnected {
            // Bluetooth came back after a toggle: the reconnect that failed while it was off is not retried.
            log("Garmin: Bluetooth back on - reconnecting")
            connect(p.identifier)
        } else if scanning {
            scan()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard Self.isCirqa(name: name) || services.contains(Self.mlService) else { return }
        let id = peripheral.identifier
        if seenPeripherals[id] == nil { log("Garmin: found \(LiveState.logSafeDeviceName(name ?? "Garmin")) rssi \(RSSI.intValue)") }
        seenPeripherals[id] = peripheral
        discovered = StandardHRSource.upsertByProximity(
            discovered, DiscoveredBand(id: id, name: name ?? "CIRQA Smart Band", rssi: RSSI.intValue))
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Garmin: connected - discovering services")
        resetSession()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Garmin: failed to connect - \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        log("Garmin: disconnected\(error.map { " - \($0.localizedDescription)" } ?? " (clean)")")
        resetSession()
        flush()
        if feedsLive { live.connected = false }
        // Reconnect while this source is the active one (a stop() clears `peripheral` first).
        if self.peripheral?.identifier == peripheral.identifier, feedsLive {
            // Back off after pairing refusals (5 s, 10 s … capped at 60 s) instead of reconnecting every second.
            let delay = encryptionFailures == 0 ? 0 : min(60, 5 * encryptionFailures)
            log(delay == 0 ? "Garmin: reconnecting" : "Garmin: reconnecting in \(delay) s")
            Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
                self.central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GarminCirqaSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Garmin: service discovery failed - \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        log("Garmin: services " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        // Standard heart rate first: it may not need a paired link, so live HR can flow even while the
        // multi-link channel is refused. The multi-link step starts once that subscription settles.
        if let hr = services.first(where: { $0.uuid == Self.stdHRService }) {
            peripheral.discoverCharacteristics([Self.stdHRMeasurement], for: hr)
        } else {
            discoverMultiLink(peripheral)
        }
    }

    private func discoverMultiLink(_ peripheral: CBPeripheral) {
        guard let ml = peripheral.services?.first(where: { $0.uuid == Self.mlService }) else {
            log("Garmin: multi-link service NOT FOUND - this band does not expose the V2 protocol")
            return
        }
        peripheral.discoverCharacteristics(nil, for: ml)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Garmin: characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        if service.uuid == Self.stdHRService {
            if let m = chars.first(where: { $0.uuid == Self.stdHRMeasurement }) {
                log("Garmin: enabling standard heart rate (0x2A37)")
                peripheral.setNotifyValue(true, for: m)
            } else {
                discoverMultiLink(peripheral)
            }
            return
        }
        log("Garmin: characteristics " + chars.map { "\($0.uuid.uuidString.prefix(8))[\($0.properties.rawValue)]" }
            .joined(separator: " "))
        // First complete notify/write pair (notify 0x2810+i, write 0x2820+i).
        for i in 0..<5 {
            let rx = CBUUID(string: GarminGFDI.multiLinkNotifyUUID(i))
            let tx = CBUUID(string: GarminGFDI.multiLinkWriteUUID(i))
            if let n = chars.first(where: { $0.uuid == rx }), let w = chars.first(where: { $0.uuid == tx }) {
                notifyChar = n
                writeChar = w
                log("Garmin: using multi-link pair \(i) - enabling notifications")
                peripheral.setNotifyValue(true, for: n)
                return
            }
        }
        log("Garmin: no complete multi-link characteristic pair found")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == Self.stdHRMeasurement {
            log(error.map { "Garmin: standard heart rate FAILED - \($0.localizedDescription)" }
                ?? "Garmin: standard heart rate on")
            // The band drops the whole link when it refuses the multi-link channel. After two refusals,
            // keep the working standard-HR link instead of losing it again on every reconnect.
            if error == nil, encryptionFailures >= 2 {
                log("Garmin: multi-link refused \(encryptionFailures)x - staying on standard heart rate only")
                return
            }
            discoverMultiLink(peripheral)
            return
        }
        guard characteristic.uuid == notifyChar?.uuid else { return }
        if let error {
            log("Garmin: enabling notifications FAILED - \(error.localizedDescription)")
            if let att = error as? CBATTError,
               att.code == .insufficientEncryption || att.code == .insufficientAuthentication {
                encryptionFailures += 1
                // Only what was observed: the band refused an unencrypted link. Why iOS did not pair is unknown here.
                log("Garmin: band requires a paired (encrypted) link - refusal #\(encryptionFailures)")
            }
            return
        }
        encryptionFailures = 0
        log("Garmin: notifications on - resetting the multi-link session")
        writeRaw(GarminGFDI.closeAllRequest())
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error { log("Garmin: write failed - \(error.localizedDescription)") }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == Self.stdHRMeasurement {
            handleStandardHR([UInt8](value))
        } else if characteristic.uuid == notifyChar?.uuid {
            handleNotify([UInt8](value))
        }
    }
}

extension GarminCirqaSource: LiveHRSource {}
