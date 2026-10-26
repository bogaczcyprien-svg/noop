#if os(iOS)
import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol

/// The CORE body-temperature sensor of the Breathing tab (fork addition): scans for a CORE (its Core Body
/// Temperature service, firmware 0.6.1 and later), connects, and publishes the
/// internal body temperature live.
///
/// Read-only and isolated, like `BreathingStrapLink`: its own `CBCentralManager`, never touching
/// `BLEManager` or the WHOOP link. The only write is the notify subscription on the Core Body
/// Temperature characteristic; the CORE control point is never written. The last sensor used is
/// remembered so the next session reconnects without a scan.
@MainActor
final class CoreTempLink: NSObject, ObservableObject {

    enum State: Equatable {
        case idle, bluetoothOff, scanning, connecting, connected, disconnected
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [BreathingSensorFound] = []
    @Published private(set) var sensorName: String?
    /// Internal body temperature, °C, from the latest reading that carried one.
    @Published private(set) var coreC: Double?
    @Published private(set) var heatStrainIndex: Double?
    /// 0 invalid · 1 poor · 2 fair · 3 good · 4 excellent.
    @Published private(set) var quality: Int?
    private var coreAt: Date?

    /// A reading older than this is not shown as current.
    static let staleAfter: TimeInterval = 30

    private static let coreService = CBUUID(string: CoreBodyTempDecode.serviceUUID)
    private static let temperature = CBUUID(string: CoreBodyTempDecode.temperatureCharacteristicUUID)
    private static let lastSensorKey = "noop.breathing.lastCoreId"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var wantScan = false
    private var wantReconnect = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var lastSensorId: UUID? {
        UserDefaults.standard.string(forKey: Self.lastSensorKey).flatMap(UUID.init(uuidString:))
    }

    var isConnected: Bool { state == .connected }

    /// The internal temperature now, °C, or nil when there is no fresh reading.
    func currentCoreC(now: Date = Date()) -> Double? {
        guard isConnected, let c = coreC, let at = coreAt, now.timeIntervalSince(at) <= Self.staleAfter else { return nil }
        return c
    }

    func scan() {
        found = []
        wantScan = true
        guard central.state == .poweredOn else {
            state = central.state == .poweredOff ? .bluetoothOff : .idle
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.coreService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        wantScan = false
        if central.state == .poweredOn { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    func reconnectLast() {
        guard !isConnected, state != .connecting, let id = lastSensorId else { return }
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
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastSensorKey)
        central.connect(p, options: nil)
    }

    func disconnect() {
        wantReconnect = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        clearReading()
        state = .idle
    }

    private func clearReading() {
        coreC = nil; coreAt = nil; heatStrainIndex = nil; quality = nil
    }

    private func handle(_ bytes: [UInt8]) {
        guard let r = CoreBodyTempDecode.parse(bytes) else { return }
        quality = r.quality
        heatStrainIndex = r.heatStrainIndex
        if let c = r.coreC {
            coreC = c
            coreAt = Date()
        }
    }
}

// Same main-thread central as `BreathingStrapLink`, so MainActor isolation is sound.
extension CoreTempLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { scan() }
            if wantReconnect, let id = lastSensorId { connect(id) }
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
            ?? "CORE"
        seen[peripheral.identifier] = peripheral
        var list = found.filter { $0.id != peripheral.identifier }
        list.append(BreathingSensorFound(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        found = list.sorted { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        sensorName = peripheral.name
        peripheral.discoverServices([Self.coreService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        clearReading()
        state = .disconnected
        if error != nil, let id = lastSensorId { connect(id) }
    }
}

extension CoreTempLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == Self.coreService {
            peripheral.discoverCharacteristics([Self.temperature], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.temperature {
            peripheral.setNotifyValue(true, for: c)
            peripheral.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.temperature, let data = characteristic.value else { return }
        handle([UInt8](data))
    }
}
#endif
