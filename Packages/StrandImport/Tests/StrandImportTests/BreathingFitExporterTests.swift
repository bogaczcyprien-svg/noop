import XCTest
@testable import StrandImport

/// The breathing-session FIT file must be well formed and decode back through the importer.
final class BreathingFitExporterTests: XCTestCase {

    private let start = 1_760_000_000

    private func session(seconds: Int) -> [BreathingFitExporter.Sample] {
        (0..<seconds).map { i in
            BreathingFitExporter.Sample(ts: start + i, hr: 60 + (i % 10), breathsPerMin: i < 10 ? nil : 6.0)
        }
    }

    func testCrcAndHeaderAreValid() {
        let bytes = [UInt8](BreathingFitExporter.build(samples: session(seconds: 300), rrMs: [1000, 980, 1020],
                                                       startTs: start, endTs: start + 300))
        XCTAssertEqual(bytes[0], 12)
        XCTAssertEqual(Array(bytes[8..<12]), Array(".FIT".utf8))
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        XCTAssertEqual(bytes.count, 12 + dataSize + 2)
        let crc = Int(bytes[bytes.count - 2]) | (Int(bytes[bytes.count - 1]) << 8)
        XCTAssertEqual(RouteExporter.fitCrc(Array(bytes[0..<(bytes.count - 2)])), crc)
    }

    func testRoundTripsThroughTheImporter() throws {
        let data = BreathingFitExporter.build(samples: session(seconds: 300), rrMs: Array(repeating: 1000, count: 290),
                                              startTs: start, endTs: start + 300)
        let a = try XCTUnwrap(ActivityFileImporter.parse(data: data, filename: "breathing.fit").activity)
        XCTAssertEqual(Int(a.start.timeIntervalSince1970), start)
        XCTAssertEqual(Int(a.end.timeIntervalSince1970), start + 300)
        // Mean of 60...69 is 64.5, rounded to 65; max is 69.
        XCTAssertEqual(a.avgHr, 65)
        XCTAssertEqual(a.maxHr, 69)
        XCTAssertEqual(a.hrSampleCount, 300)
    }

    func testRespirationRateIsEncodedPerSecondAndUnknownIsInvalid() {
        let bytes = [UInt8](BreathingFitExporter.build(
            samples: [.init(ts: start, hr: 60, breathsPerMin: nil), .init(ts: start + 1, hr: nil, breathsPerMin: 5.0),
                      .init(ts: start + 2, hr: 61, breathsPerMin: 6.25)],
            rrMs: [], startTs: start, endTs: start + 3))
        // file_id: definition 6 + 3*3 = 15 bytes, data 1 + 7 = 8 → record definition starts at 12 + 23.
        let recordData = 12 + 23 + 6 + 3 * 3
        // record 1: header, ts(4), hr = 60, resp = 0xFFFF.
        XCTAssertEqual(bytes[recordData + 5], 60)
        XCTAssertEqual(Array(bytes[(recordData + 6)...(recordData + 7)]), [0xFF, 0xFF])
        // The second without HR is skipped; the next record is the third second: hr 61, resp 625 = 0x0271.
        let second = recordData + 8
        XCTAssertEqual(bytes[second + 5], 61)
        XCTAssertEqual(Array(bytes[(second + 6)...(second + 7)]), [0x71, 0x02])
    }

    /// With a CORE sensor, record field 139 carries the internal temperature (°C × 100); a second
    /// without a reading is the invalid value, and the file still decodes.
    func testCoreTemperatureIsEncodedPerSecond() throws {
        let samples: [BreathingFitExporter.Sample] = [
            .init(ts: start, hr: 60, breathsPerMin: 6.0, coreTempC: 37.12),
            .init(ts: start + 1, hr: 61, breathsPerMin: 6.0, coreTempC: nil),
            .init(ts: start + 2, hr: 62, breathsPerMin: 6.0, coreTempC: 37.20),
        ]
        let data = BreathingFitExporter.build(samples: samples, rrMs: [], startTs: start, endTs: start + 3)
        let bytes = [UInt8](data)
        // Record definition: 6 + 4 fields × 3 = 18 bytes; the field list ends with (139, 2, 0x84).
        let recordDef = 12 + 23
        XCTAssertEqual(bytes[recordDef + 5], 4)
        XCTAssertEqual(Array(bytes[(recordDef + 15)...(recordDef + 17)]), [139, 2, 0x84])
        let first = recordDef + 18
        // header(1) ts(4) hr(1) resp(2) core(2): 3712 = 0x0E80.
        XCTAssertEqual(Array(bytes[(first + 8)...(first + 9)]), [0x80, 0x0E])
        let second = first + 10
        XCTAssertEqual(Array(bytes[(second + 8)...(second + 9)]), [0xFF, 0xFF])
        XCTAssertNotNil(ActivityFileImporter.parse(data: data, filename: "breathing.fit").activity)
    }

    func testImplausibleCoreTemperatureIsNotWritten() {
        let withNoise = BreathingFitExporter.build(
            samples: [.init(ts: start, hr: 60, breathsPerMin: nil, coreTempC: 0)], rrMs: [], startTs: start, endTs: start + 1)
        let without = BreathingFitExporter.build(
            samples: [.init(ts: start, hr: 60, breathsPerMin: nil)], rrMs: [], startTs: start, endTs: start + 1)
        XCTAssertEqual(withNoise, without)
    }
}
