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
}
