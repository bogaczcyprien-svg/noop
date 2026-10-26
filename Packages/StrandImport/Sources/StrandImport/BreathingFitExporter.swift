import Foundation

/// A breathing session as a FIT activity file, for upload to intervals.icu (fork addition, iOS
/// Breathing tab). Pure; the sibling of ``RouteExporter/buildFit(route:startTs:endTs:sport:distanceM:energyKcal:avgHr:maxHr:)``
/// and decodable by ``ActivityFileImporter``.
///
/// Carried per second (record, global 20): heart rate (field 3) and breathing rate as
/// `enhanced_respiration_rate` (field 108, breaths/min × 100), the field Garmin devices write and
/// intervals.icu charts. Every R-R interval goes into hrv messages (global 78, field 0, seconds × 1000),
/// which intervals.icu reads for HRV. Session (global 18) carries start, duration, sport, average and
/// maximum heart rate.
///
/// When a CORE sensor was worn, the internal body temperature goes in record field 139
/// `core_temperature` (°C × 100, uint16), and its average, minimum and maximum in the lap (158–160) and
/// session (208–210) fields, the native FIT numbers CORE's integration notes ask for. Without any
/// temperature the record layout is unchanged.
public enum BreathingFitExporter {

    /// One second of the session. `breathsPerMin` and `coreTempC` nil = unknown (written as the FIT
    /// invalid value); a second with no `hr` is not written.
    public struct Sample: Equatable, Sendable {
        public let ts: Int
        public let hr: Int?
        public let breathsPerMin: Double?
        public let coreTempC: Double?
        public init(ts: Int, hr: Int?, breathsPerMin: Double?, coreTempC: Double? = nil) {
            self.ts = ts; self.hr = hr; self.breathsPerMin = breathsPerMin; self.coreTempC = coreTempC
        }
    }

    /// A plausible internal temperature, °C × 100, or nil.
    static func coreCentiC(_ c: Double?) -> UInt16? {
        guard let c, c > 25, c < 45 else { return nil }
        return UInt16((c * 100).rounded())
    }

    /// FIT `sport` 10 = training (a generic session that is neither run nor ride).
    static let sportTraining = 10

    public static func build(samples: [Sample], rrMs: [Int], startTs: Int, endTs: Int) -> Data {
        var body: [UInt8] = []

        // file_id: type = activity, manufacturer = development, time_created.
        defn(&body, local: 0, global: 0, fields: [(0, 1, 0x00), (1, 2, 0x84), (4, 4, 0x86)])
        body.append(0)
        u8(&body, 4); u16(&body, 255); u32(&body, fitTime(startTs))

        // record: timestamp, heart_rate, enhanced_respiration_rate (+ core_temperature with a CORE).
        let written = samples.sorted(by: { $0.ts < $1.ts }).filter { $0.hr != nil }
        let cores = written.compactMap { coreCentiC($0.coreTempC) }
        var recordFields = [(253, 4, 0x86), (3, 1, 0x02), (108, 2, 0x84)]
        if !cores.isEmpty { recordFields.append((139, 2, 0x84)) }
        defn(&body, local: 1, global: 20, fields: recordFields)
        // A second without HR is dropped: FIT marks it 0xFF, which some readers (this repo's importer
        // included) take as a real 255 bpm.
        for s in written {
            body.append(1)
            u32(&body, fitTime(s.ts))
            u8(&body, min(max(s.hr ?? 0, 1), 254))
            if let b = s.breathsPerMin, b > 0 {
                u16(&body, UInt16(min((b * 100).rounded(), 65_534)))
            } else {
                u16(&body, 0xFFFF)
            }
            if !cores.isEmpty { u16(&body, coreCentiC(s.coreTempC) ?? 0xFFFF) }
        }
        let coreStats: (avg: UInt16, min: UInt16, max: UInt16)? = cores.isEmpty ? nil : (
            UInt16((Double(cores.reduce(0) { $0 + Int($1) }) / Double(cores.count)).rounded()),
            cores.min()!, cores.max()!)

        // hrv: one R-R per message, seconds × 1000 (so the raw value is milliseconds).
        defn(&body, local: 2, global: 78, fields: [(0, 2, 0x84)])
        for rr in rrMs where rr > 0 && rr < 0xFFFF {
            body.append(2)
            u16(&body, UInt16(rr))
        }

        let hrs = samples.compactMap(\.hr)
        let avgHr = hrs.isEmpty ? nil : Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded())
        let maxHr = hrs.max()
        let elapsedMs = UInt32(max(0, endTs - startTs)) &* 1000

        // lap: one, spanning the session.
        var lapFields = [(253, 4, 0x86), (2, 4, 0x86), (7, 4, 0x86), (8, 4, 0x86)]
        if coreStats != nil { lapFields += [(158, 2, 0x84), (159, 2, 0x84), (160, 2, 0x84)] }
        defn(&body, local: 3, global: 19, fields: lapFields)
        body.append(3)
        u32(&body, fitTime(endTs)); u32(&body, fitTime(startTs)); u32(&body, elapsedMs); u32(&body, elapsedMs)
        if let c = coreStats { u16(&body, c.avg); u16(&body, c.min); u16(&body, c.max) }

        // session: only the fields that are known. A missing HR is omitted, never sentinelled.
        var sf: [(Int, Int, Int)] = []
        var sd: [UInt8] = []
        sf.append((253, 4, 0x86)); u32(&sd, fitTime(endTs))
        sf.append((2, 4, 0x86)); u32(&sd, fitTime(startTs))
        sf.append((7, 4, 0x86)); u32(&sd, elapsedMs)
        sf.append((8, 4, 0x86)); u32(&sd, elapsedMs)
        sf.append((5, 1, 0x00)); u8(&sd, sportTraining)
        if let avgHr { sf.append((16, 1, 0x02)); u8(&sd, min(max(avgHr, 1), 254)) }
        if let maxHr { sf.append((17, 1, 0x02)); u8(&sd, min(max(maxHr, 1), 254)) }
        if let c = coreStats {
            sf.append((208, 2, 0x84)); u16(&sd, c.avg)
            sf.append((209, 2, 0x84)); u16(&sd, c.min)
            sf.append((210, 2, 0x84)); u16(&sd, c.max)
        }
        defn(&body, local: 4, global: 18, fields: sf)
        body.append(4)
        body.append(contentsOf: sd)

        // activity: one session.
        defn(&body, local: 5, global: 34, fields: [(253, 4, 0x86), (1, 2, 0x84), (2, 1, 0x00)])
        body.append(5)
        u32(&body, fitTime(endTs)); u16(&body, 1); u8(&body, 0)

        var out: [UInt8] = []
        u8(&out, 12); u8(&out, 0x20); u16(&out, 2140); u32(&out, UInt32(body.count))
        out.append(contentsOf: Array(".FIT".utf8))
        out.append(contentsOf: body)
        u16(&out, UInt16(RouteExporter.fitCrc(out)))
        return Data(out)
    }

    // MARK: - Byte helpers (the same little-endian layout as `RouteExporter`)

    private static func fitTime(_ unix: Int) -> UInt32 {
        UInt32(min(max(0, unix - RouteExporter.fitEpoch), 0xFFFF_FFFF))
    }

    private static func defn(_ b: inout [UInt8], local: Int, global: Int, fields: [(Int, Int, Int)]) {
        u8(&b, 0x40 | (local & 0x0F))
        u8(&b, 0)
        u8(&b, 0)
        u16(&b, UInt16(global))
        u8(&b, fields.count)
        for f in fields { u8(&b, f.0); u8(&b, f.1); u8(&b, f.2) }
    }

    private static func u8(_ b: inout [UInt8], _ v: Int) { b.append(UInt8(v & 0xFF)) }
    private static func u16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
    }
    private static func u32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF))
        b.append(UInt8((v >> 16) & 0xFF)); b.append(UInt8((v >> 24) & 0xFF))
    }
}
