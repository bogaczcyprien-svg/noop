import XCTest
@testable import WhoopProtocol

/// `CoreBodyTempDecode` against the CORE Core Body Temperature Service specification V2.2.
final class CoreBodyTempDecodeTests: XCTestCase {

    /// The specification's worked example (implementation notes V3.3, table 5), as its Python dump
    /// shows it: b"7\x19\x0f\xa4\r/\x00\x11\x00'".
    func testSpecExamplePacket() throws {
        let r = try XCTUnwrap(CoreBodyTempDecode.parse([0x37, 0x19, 0x0F, 0xA4, 0x0D, 0x2F, 0x00, 0x11, 0x00, 0x27]))
        XCTAssertEqual(try XCTUnwrap(r.coreC), 38.65, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.skinC), 34.92, accuracy: 1e-9)
        XCTAssertEqual(r.quality, 1)          // poor
        XCTAssertNil(r.heartRate)             // supported, not receiving: sent as 0
        XCTAssertEqual(try XCTUnwrap(r.heatStrainIndex), 3.9, accuracy: 1e-9)
    }

    func testCoreOnlyPacket() throws {
        // 37.12 °C = 3712 = 0x0E80.
        let r = try XCTUnwrap(CoreBodyTempDecode.parse([0x00, 0x80, 0x0E]))
        XCTAssertEqual(try XCTUnwrap(r.coreC), 37.12, accuracy: 1e-9)
        XCTAssertNil(r.skinC)
        XCTAssertNil(r.quality)
        XCTAssertNil(r.heatStrainIndex)
    }

    func testNotAvailableCoreIsNil() throws {
        let r = try XCTUnwrap(CoreBodyTempDecode.parse([0x04, 0xFF, 0x7F, 0x07]))
        XCTAssertNil(r.coreC)
        XCTAssertNil(r.quality)               // 111 = N/A
    }

    func testFahrenheitIsConvertedToCelsius() throws {
        // 98.60 °F = 9860 = 0x2684 -> 37.0 °C.
        let r = try XCTUnwrap(CoreBodyTempDecode.parse([0x08, 0x84, 0x26]))
        XCTAssertEqual(try XCTUnwrap(r.coreC), 37.0, accuracy: 1e-9)
    }

    func testHeartRateAndZeroHeatStrainAreKept() throws {
        // Flags: quality (bit 2), heart rate (bit 4), heat strain (bit 5). HSI 0.0 is a real value.
        let r = try XCTUnwrap(CoreBodyTempDecode.parse([0x34, 0x80, 0x0E, 0x14, 0x8C, 0x00]))
        XCTAssertEqual(r.quality, 4)          // excellent
        XCTAssertEqual(r.heartRate, 140)
        XCTAssertEqual(r.heatStrainIndex, 0.0)
    }

    func testTruncatedPacketsNeverCrash() {
        XCTAssertNil(CoreBodyTempDecode.parse([]))
        XCTAssertNil(CoreBodyTempDecode.parse([0x37]))
        XCTAssertNil(CoreBodyTempDecode.parse([0x37, 0x19]))
        // Core present, every optional field cut off.
        let r = CoreBodyTempDecode.parse([0x37, 0x19, 0x0F, 0xA4])
        XCTAssertEqual(r?.coreC ?? 0, 38.65, accuracy: 1e-9)
        XCTAssertNil(r?.skinC)
        XCTAssertNil(r?.heatStrainIndex)
    }
}
