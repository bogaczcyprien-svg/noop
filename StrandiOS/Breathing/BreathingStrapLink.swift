#if os(iOS)
import Foundation
import Combine
import CoreBluetooth

/// A sensor seen during a Breathing-tab scan (chest strap or CORE).
struct BreathingSensorFound: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// The chest strap of the Breathing tab (fork addition): scans for a standard Bluetooth heart-rate strap
/// (service 0x180D), connects, and publishes its heart rate and beat-to-beat R-R intervals live.
///
/// Read-only and isolated, like `StandardHRSource`: its own `CBCentralManager`, never touching
/// `BLEManager` or the WHOOP link, and it persists nothing — the session that reads it decides what to
/// keep. The only write is the standard notify subscription on 0x2A37. The last strap used is
/// remembered so the next session reconnects without a scan.
@MainActor
final class BreathingStrapLink: NSObject, ObservableObject {

    typealias Found = BreathingSensorFound

    enum State: Equatable {
        case idle, bluetoothOff, scanning, connecting, connected, disconnected
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var strapName: String?
    @Published private(set) var heartRate: Int?
    /// Bumped on every notification carrying R-R, so a reader can drain `takeBeats()`.
    @Published private(set) var beatSeq = 0

    /// Beats not yet taken by the session: (unix seconds, fractional; R-R ms).
    private var pendingBeats: [(ts: Double, rrMs: Int)] = []

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let lastStrapKey = "noop.breathing.lastStrapId"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var wantScan = false
    private var wantReconnect = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var lastStrapId: UUID? {
        UserDefaults.standard.string(forKey: Self.lastStrapKey).flatMap(UUID.init(uuidString:))
    }

    var isConnected: Bool { state == .connected }

    /// Scan for straps. Results land in `found`, closest first.
    func scan() {
        found = []
        wantScan = true
        guard central.state == .poweredOn else {
            state = central.state == .poweredOff ? .bluetoothOff : .idle
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.heartRateService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        wantScan = false
        if central.state == .poweredOn { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    /// Reconnect the last strap without a scan, when there is one.
    func reconnectLast() {
        guard !isConnected, state != .connecting, let id = lastStrapId else { return }
        wantReconnect = true
        guard central.state == .poweredOn else { return }
        connect(id)
    }

    func connect(_ id: UUID) {
        stopScan()
        guard central.state == .poweredOn else { wantReconnect = true; return }
        guard let p = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            scan()
            return
        }
        seen[id] = p
        peripheral = p
        p.delegate = self
        state = .connecting
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastStrapKey)
        central.connect(p, options: nil)
    }

    func disconnect() {
        wantReconnect = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        heartRate = nil
        state = .idle
    }

    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.lastStrapKey)
        strapName = nil
    }

    /// Hand over the beats received since the last call.
    func takeBeats() -> [(ts: Double, rrMs: Int)] {
        defer { pendingBeats.removeAll() }
        return pendingBeats
    }

    private func handle(_ bytes: [UInt8]) {
        guard let parsed = StandardHeartRate.parse(bytes) else { return }
        if parsed.hr > 0 { heartRate = parsed.hr }
        guard !parsed.rr.isEmpty else { return }
        // A notification carries the beats that ended just before it; place them back in time from now.
        let now = Date().timeIntervalSince1970
        var t = now
        var beats: [(ts: Double, rrMs: Int)] = []
        for rr in parsed.rr.reversed() where rr > 0 {
            beats.append((ts: t, rrMs: rr))
            t -= Double(rr) / 1000.0
        }
        pendingBeats.append(contentsOf: beats.reversed())
        beatSeq &+= 1
    }
}

// The queue-less central delivers callbacks on the main thread, so MainActor isolation is sound;
// @preconcurrency lets this @MainActor type satisfy the nonisolated requirements (the
// `StandardHRSource` / `BLEManager` pattern).
extension BreathingStrapLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { scan() }
            if wantReconnect, let id = lastStrapId { connect(id) }
        case .poweredOff:
            state = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? String(localized: "Heart rate strap")
        seen[peripheral.identifier] = peripheral
        var list = found.filter { $0.id != peripheral.identifier }
        list.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        found = list.sorted { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        strapName = peripheral.name
        peripheral.discoverServices([Self.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        heartRate = nil
        state = .disconnected
        // An unexpected drop (error set) mid-session: try to come back once.
        if error != nil, let id = lastStrapId { connect(id) }
    }
}

extension BreathingStrapLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == Self.heartRateService {
            peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement, let data = characteristic.value else { return }
        handle([UInt8](data))
    }
}
#endif
