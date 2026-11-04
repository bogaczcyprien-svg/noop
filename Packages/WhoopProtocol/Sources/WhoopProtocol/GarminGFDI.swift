import Foundation

/// EXPERIMENTAL clean-room codec for the Garmin BLE stack (multi-link handles + GFDI messages), used by the
/// iOS Garmin CIRQA lane. Pure: no CoreBluetooth, no I/O, so every byte layout here is pinned by
/// `GarminGFDITests` without a band.
///
/// Re-derived from PROTOCOL FACTS only (field order, sizes, ids, the CRC table) documented by Gadgetbridge's
/// Garmin support. No Gadgetbridge code is copied: it is GPL/AGPL, NOOP is not (see ATTRIBUTION.md).
///
/// Wire shape, outermost first:
/// 1. BLE notify/write on the multi-link (ML) characteristic pair: `[handle][chunk]`. Handle 0 is the handle
///    management channel; the band assigns one handle per registered service (GFDI, realtime HR, …).
/// 2. On the GFDI handle, the chunks reassemble into COBS frames (leading AND trailing 0x00).
/// 3. A decoded COBS frame is one GFDI message: `[len u16][id u16][payload][crc u16]`, all little-endian,
///    `len` counting the whole message and the CRC covering everything before it.
public enum GarminGFDI {

    // MARK: - Constants

    /// Seconds between the Unix epoch and Garmin's (1990-01-01T00:00:00Z).
    public static let garminEpochOffset: Int = 631_065_600

    /// The multi-link service and its characteristic pairs (notify 0x2810+i, write 0x2820+i).
    public static let multiLinkService = "6A4E2800-667B-11E3-949A-0800200C9A66"
    public static func multiLinkNotifyUUID(_ i: Int) -> String {
        String(format: "6A4E28%02X-667B-11E3-949A-0800200C9A66", 0x10 + i)
    }
    public static func multiLinkWriteUUID(_ i: Int) -> String {
        String(format: "6A4E28%02X-667B-11E3-949A-0800200C9A66", 0x20 + i)
    }

    /// The client id we register handles under. Any constant works; the band echoes it back.
    public static let clientId: UInt64 = 2

    /// Multi-link service codes (the u16 a REGISTER request names).
    public enum Service: UInt16, Sendable {
        case gfdi = 1
        case realtimeHR = 6
        case realtimeSteps = 7
        case realtimeHRV = 12
        case realtimeStress = 13
        case realtimeSpO2 = 19
        case realtimeBodyBattery = 20
        case realtimeRespiration = 21
    }

    /// GFDI message ids.
    public enum MessageId: UInt16, Sendable {
        case response = 5000
        case downloadRequest = 5002
        case fileTransferData = 5004
        case filter = 5007
        case setFileFlag = 5008
        case batteryStatus = 5023
        case deviceInformation = 5024
        case systemEvent = 5030
        case synchronization = 5037
        case protobufRequest = 5043
        case protobufResponse = 5044
        case configuration = 5050
        case currentTimeRequest = 5052
    }

    /// RESPONSE status byte.
    public enum Status: UInt8, Sendable {
        case ack = 0, nak = 1, unsupported = 2, decodeError = 3, crcError = 4, lengthError = 5
    }

    /// SYSTEM_EVENT types (the byte after the id).
    public enum SystemEvent: UInt8, Sendable {
        case syncComplete = 0
        case pairComplete = 4
        case syncReady = 8
        case setupWizardComplete = 14
    }

    // MARK: - CRC (Garmin nibble-table CRC-16, seed-chainable)

    private static let crcTable: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    /// CRC over `bytes`, starting from `seed` (0 for a fresh message; the running value for file chunks).
    public static func crc16<C: Collection>(_ bytes: C, seed: UInt16 = 0) -> UInt16 where C.Element == UInt8 {
        var crc = seed
        for b in bytes {
            crc = ((crc >> 4) & 0x0FFF) ^ crcTable[Int(crc & 0xF)] ^ crcTable[Int(b & 0xF)]
            crc = ((crc >> 4) & 0x0FFF) ^ crcTable[Int(crc & 0xF)] ^ crcTable[Int(b >> 4)]
        }
        return crc
    }

    // MARK: - COBS (Garmin flavour: 0x00 before and after)

    /// Standard COBS, wrapped in a leading and a trailing 0x00.
    public static func cobsEncode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x00]
        var codeIndex = out.count
        out.append(0)   // placeholder for the first code
        var code: UInt8 = 1
        for b in data {
            if b == 0 {
                out[codeIndex] = code
                codeIndex = out.count
                out.append(0)
                code = 1
            } else {
                out.append(b)
                code += 1
                if code == 0xFF {
                    out[codeIndex] = code
                    codeIndex = out.count
                    out.append(0)
                    code = 1
                }
            }
        }
        out[codeIndex] = code
        out.append(0x00)
        return out
    }

    /// Decode the COBS body between the two 0x00 delimiters (delimiters NOT included). nil if malformed.
    public static func cobsDecodeBody(_ body: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        while i < body.count {
            let code = Int(body[i])
            guard code != 0, i + code <= body.count else { return nil }
            out.append(contentsOf: body[(i + 1)..<(i + code)])
            i += code
            if code < 0xFF && i < body.count { out.append(0) }
        }
        return out
    }

    /// Reassembles COBS frames from GFDI-handle chunks (handle byte already stripped).
    public struct CobsAssembler: Sendable {
        private var buffer: [UInt8] = []
        public init() {}

        /// Feed one chunk; returns every complete decoded frame it closed (usually 0 or 1).
        public mutating func feed(_ chunk: [UInt8]) -> [[UInt8]] {
            buffer.append(contentsOf: chunk)
            var frames: [[UInt8]] = []
            while true {
                // Drop leading delimiters, then look for the closing one.
                guard let start = buffer.firstIndex(where: { $0 != 0 }) else {
                    if buffer.count > 1 { buffer = [0] }   // keep one delimiter as a possible frame start
                    return frames
                }
                guard let end = buffer[start...].firstIndex(of: 0) else {
                    if buffer.count > 16_384 { buffer.removeAll() }   // runaway guard
                    return frames
                }
                if let decoded = GarminGFDI.cobsDecodeBody(Array(buffer[start..<end])) {
                    frames.append(decoded)
                }
                buffer.removeSubrange(0..<end)   // keep the closing 0x00: it can open the next frame
            }
        }

        public mutating func reset() { buffer.removeAll() }
    }

    // MARK: - GFDI message envelope

    /// One parsed GFDI message.
    public struct Message: Equatable, Sendable {
        public let id: UInt16
        public let payload: [UInt8]
    }

    /// Build `[len][id][payload][crc]`.
    public static func frame(id: UInt16, payload: [UInt8]) -> [UInt8] {
        var out = Bytes.u16(UInt16(payload.count + 6)) + Bytes.u16(id) + payload
        out += Bytes.u16(crc16(out))
        return out
    }

    /// Parse and verify a decoded frame. nil on a length or CRC mismatch.
    public static func parse(_ frame: [UInt8]) -> Message? {
        guard frame.count >= 6 else { return nil }
        let len = Int(Bytes.readU16(frame, 0))
        guard len == frame.count else { return nil }
        let crc = Bytes.readU16(frame, frame.count - 2)
        guard crc == crc16(frame[0..<(frame.count - 2)]) else { return nil }
        var id = Bytes.readU16(frame, 2)
        if id & 0x8000 != 0 { id = (id & 0x00FF) + 5000 }   // compact id form
        return Message(id: id, payload: Array(frame[4..<(frame.count - 2)]))
    }

    /// A RESPONSE (5000) to `original`, with optional trailing fields.
    public static func response(to original: UInt16, status: Status = .ack, extra: [UInt8] = []) -> [UInt8] {
        frame(id: MessageId.response.rawValue, payload: Bytes.u16(original) + [status.rawValue] + extra)
    }

    // MARK: - Device information (5024)

    public struct DeviceInformation: Equatable, Sendable {
        public let protocolVersion: UInt16
        public let productNumber: UInt16
        public let unitNumber: UInt32
        public let softwareVersion: UInt16
        public let maxPacketSize: UInt16
        public let bluetoothName: String
        public let deviceName: String
        public let model: String

        /// "3.20" style, from the u16 the band sends (v/100 . v%100).
        public var softwareVersionString: String {
            String(format: "%d.%02d", Int(softwareVersion) / 100, Int(softwareVersion) % 100)
        }
    }

    public static func parseDeviceInformation(_ p: [UInt8]) -> DeviceInformation? {
        var r = Bytes.Reader(p)
        guard let pv = r.u16(), let pn = r.u16(), let un = r.u32(), let sw = r.u16(), let mp = r.u16(),
              let bt = r.string(), let dn = r.string(), let md = r.string() else { return nil }
        return DeviceInformation(protocolVersion: pv, productNumber: pn, unitNumber: un, softwareVersion: sw,
                                 maxPacketSize: mp, bluetoothName: bt, deviceName: dn, model: md)
    }

    /// Our reply to DEVICE_INFORMATION: a RESPONSE carrying the host's own identity.
    public static func deviceInformationReply(to info: DeviceInformation, hostName: String,
                                              manufacturer: String, device: String) -> [UInt8] {
        var extra: [UInt8] = []
        extra += Bytes.u16(150)          // our protocol version
        extra += Bytes.u16(0xFFFF)       // product number: none
        extra += Bytes.u32(0xFFFF_FFFF)  // unit number: none
        extra += Bytes.u16(7791)         // software version
        extra += Bytes.u16(0xFFFF)       // max packet size: no limit of our own
        extra += Bytes.string(hostName) + Bytes.string(manufacturer) + Bytes.string(device)
        extra.append(info.protocolVersion / 100 == 1 ? 1 : 0)
        return response(to: MessageId.deviceInformation.rawValue, extra: extra)
    }

    // MARK: - Configuration (5050)

    /// Capability ordinals NOT advertised by the host (everything else 0…128 is set).
    private static let capabilitiesWithheld: Set<Int> = Set([22, 23, 28]).union(104...111).union(114...119)

    /// The host capability bitset (17 bytes, ordinal i → byte i/8, bit i%8).
    public static var hostCapabilities: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 17)
        for i in 0...128 where !capabilitiesWithheld.contains(i) { bytes[i / 8] |= UInt8(1 << (i % 8)) }
        return bytes
    }

    /// Our CONFIGURATION message (sent back after the band's own 5050).
    public static func configurationMessage() -> [UInt8] {
        let caps = hostCapabilities
        return frame(id: MessageId.configuration.rawValue, payload: [UInt8(caps.count)] + caps)
    }

    /// The band's capability bitset out of its 5050 payload.
    public static func parseConfiguration(_ p: [UInt8]) -> [UInt8]? {
        guard let n = p.first, p.count >= 1 + Int(n) else { return nil }
        return Array(p[1..<(1 + Int(n))])
    }

    // MARK: - Current time (5052)

    /// The reply to CURRENT_TIME_REQUEST: RESPONSE carrying the reference id, Garmin time and UTC offset.
    public static func currentTimeReply(requestPayload p: [UInt8], now: Date, timeZone: TimeZone) -> [UInt8]? {
        guard p.count >= 4 else { return nil }
        let reference = Bytes.readU32(p, 0)
        let garminNow = UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970) - garminEpochOffset)
        let offset = Int32(timeZone.secondsFromGMT(for: now))
        var extra = Bytes.u32(reference) + Bytes.u32(garminNow) + Bytes.u32(UInt32(bitPattern: offset))
        extra += Bytes.u32(0) + Bytes.u32(0)   // next DST transition end/start: unknown
        return response(to: MessageId.currentTimeRequest.rawValue, extra: extra)
    }

    // MARK: - System event (5030) / filter (5007)

    public static func systemEvent(_ e: SystemEvent) -> [UInt8] {
        frame(id: MessageId.systemEvent.rawValue, payload: [e.rawValue, 0])
    }

    /// FILTER "only new files" (3), the answer to the band's SYNCHRONIZATION.
    public static func filterOnlyNew() -> [UInt8] {
        frame(id: MessageId.filter.rawValue, payload: [3])
    }

    // MARK: - Files (5002 / 5004 / 5008)

    /// DOWNLOAD_REQUEST for file `index` from `offset` (index 0 is the directory).
    public static func downloadRequest(index: UInt16, offset: UInt32 = 0, newTransfer: Bool = true,
                                       crcSeed: UInt16 = 0, size: UInt32 = 0) -> [UInt8] {
        var p = Bytes.u16(index) + Bytes.u32(offset) + [newTransfer ? 1 : 0]
        p += Bytes.u16(crcSeed) + Bytes.u32(size) + [0]
        return frame(id: MessageId.downloadRequest.rawValue, payload: p)
    }

    /// The fields of a RESPONSE to DOWNLOAD_REQUEST after the original id.
    public struct DownloadStatus: Equatable, Sendable {
        public let status: UInt8
        public let downloadStatus: UInt8?
        public let fileSize: UInt32?
        public var canProceed: Bool { status == Status.ack.rawValue && downloadStatus == 0 }
    }

    /// `responsePayload` is the whole RESPONSE payload (starts with the original id).
    public static func parseDownloadStatus(_ responsePayload: [UInt8]) -> DownloadStatus? {
        guard responsePayload.count >= 3 else { return nil }
        let status = responsePayload[2]
        guard status == Status.ack.rawValue, responsePayload.count >= 8 else {
            return DownloadStatus(status: status, downloadStatus: nil, fileSize: nil)
        }
        return DownloadStatus(status: status, downloadStatus: responsePayload[3],
                              fileSize: Bytes.readU32(responsePayload, 4))
    }

    /// One FILE_TRANSFER_DATA chunk.
    public struct FileChunk: Equatable, Sendable {
        public let crc: UInt16
        public let offset: UInt32
        public let data: [UInt8]
    }

    public static func parseFileChunk(_ p: [UInt8]) -> FileChunk? {
        guard p.count >= 7 else { return nil }
        return FileChunk(crc: Bytes.readU16(p, 1), offset: Bytes.readU32(p, 3), data: Array(p[7...]))
    }

    /// Our ACK for a chunk: transfer status (0 = OK) + the next offset we expect.
    public static func fileChunkAck(nextOffset: UInt32, transferStatus: UInt8 = 0) -> [UInt8] {
        response(to: MessageId.fileTransferData.rawValue, extra: [transferStatus] + Bytes.u32(nextOffset))
    }

    /// SET_FILE_FLAG (ARCHIVE = 0x10 marks a file as synced so the band stops offering it).
    public static func setFileFlags(index: UInt16, flags: UInt8) -> [UInt8] {
        frame(id: MessageId.setFileFlag.rawValue, payload: Bytes.u16(index) + [flags])
    }

    /// One 16-byte directory entry.
    public struct DirectoryEntry: Equatable, Sendable {
        public let index: UInt16
        public let dataType: UInt8
        public let subType: UInt8
        public let fileNumber: UInt16
        public let specificFlags: UInt8
        public let flags: UInt8
        public let size: UInt32
        /// Garmin-epoch seconds; 0 = no date.
        public let garminTimestamp: UInt32

        public var unixTimestamp: Int? { garminTimestamp == 0 ? nil : Int(garminTimestamp) + garminEpochOffset }

        /// Readable name for the FIT file kinds NOOP cares about.
        public var kindName: String {
            switch (dataType, subType) {
            case (128, 4): return "activity"
            case (128, 15), (128, 32): return "monitor"
            case (128, 28): return "monitor-daily"
            case (128, 44): return "metrics"
            case (128, 49): return "sleep"
            case (128, 68): return "hrv-status"
            case (128, 73): return "skin-temp"
            case (128, 79): return "sleep-disruption"
            default: return "type\(dataType)/\(subType)"
            }
        }
    }

    public static func parseDirectory(_ data: [UInt8]) -> [DirectoryEntry] {
        stride(from: 0, to: data.count - data.count % 16, by: 16).map { o in
            DirectoryEntry(index: Bytes.readU16(data, o), dataType: data[o + 2], subType: data[o + 3],
                           fileNumber: Bytes.readU16(data, o + 4), specificFlags: data[o + 6], flags: data[o + 7],
                           size: Bytes.readU32(data, o + 8), garminTimestamp: Bytes.readU32(data, o + 12))
        }
    }

    // MARK: - Multi-link handle management (handle 0)

    /// CLOSE_ALL: drop every handle the band holds for us (the first thing sent on a fresh link).
    public static func closeAllRequest() -> [UInt8] {
        [0x00, 0x05] + Bytes.u64(clientId) + [0x00, 0x00, 0x00]
    }

    /// REGISTER a service; `reliable` asks for the MLR layer (we ask for plain ML).
    public static func registerRequest(_ service: Service, reliable: Bool = false) -> [UInt8] {
        [0x00, 0x00] + Bytes.u64(clientId) + Bytes.u16(service.rawValue) + [reliable ? 2 : 0]
    }

    public enum HandleEvent: Equatable, Sendable {
        case closeAllDone
        case registered(service: UInt16, status: UInt8, handle: UInt8, reliable: Bool)
        case closed(service: UInt16, handle: UInt8)
        case other(type: UInt8)
    }

    /// Parse a handle-0 message (the whole notify value, handle byte included). nil if not ours.
    public static func parseHandleMessage(_ v: [UInt8]) -> HandleEvent? {
        guard v.count >= 10, v[0] == 0x00, Bytes.readU64(v, 2) == clientId else { return nil }
        switch v[1] {
        case 6: return .closeAllDone
        case 1:
            guard v.count >= 15 else { return nil }
            return .registered(service: Bytes.readU16(v, 10), status: v[12], handle: v[13], reliable: v[14] != 0)
        case 3:
            guard v.count >= 13 else { return nil }
            return .closed(service: Bytes.readU16(v, 10), handle: v[12])
        default: return .other(type: v[1])
        }
    }

    /// Split an outgoing message into BLE writes of at most `maxWrite` bytes, each prefixed with `handle`.
    public static func chunks(_ data: [UInt8], handle: UInt8, maxWrite: Int) -> [[UInt8]] {
        let room = max(1, maxWrite - 1)
        return stride(from: 0, to: data.count, by: room).map { o in
            [handle] + Array(data[o..<min(o + room, data.count)])
        }
    }

    /// Realtime HR payload (after the handle byte): `[type][hr][restingHr]`. nil when HR is 0/absent.
    public static func parseRealtimeHR(_ p: [UInt8]) -> (hr: Int, resting: Int)? {
        guard p.count >= 2, p[1] > 0 else { return nil }
        return (Int(p[1]), p.count >= 3 ? Int(p[2]) : 0)
    }

    // MARK: - Little-endian helpers

    enum Bytes {
        static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
        static func string(_ s: String) -> [UInt8] {
            let b = Array(s.utf8.prefix(255))
            return [UInt8(b.count)] + b
        }
        static func readU16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * UInt32($1)) }
        }
        static func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
        }

        struct Reader {
            let b: [UInt8]
            var o = 0
            init(_ b: [UInt8]) { self.b = b }
            mutating func u16() -> UInt16? {
                guard o + 2 <= b.count else { return nil }
                defer { o += 2 }
                return Bytes.readU16(b, o)
            }
            mutating func u32() -> UInt32? {
                guard o + 4 <= b.count else { return nil }
                defer { o += 4 }
                return Bytes.readU32(b, o)
            }
            mutating func string() -> String? {
                guard o < b.count else { return nil }
                let n = Int(b[o])
                guard o + 1 + n <= b.count else { return nil }
                defer { o += 1 + n }
                return String(decoding: b[(o + 1)..<(o + 1 + n)], as: UTF8.self)
            }
        }
    }
}
