import XCTest
@testable import WhoopProtocol

/// Byte layouts for the experimental Garmin CIRQA lane. Expected values are worked out independently of
/// `GarminGFDI` (by hand from the documented field order, the CRC with a separate implementation).
final class GarminGFDITests: XCTestCase {

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    // MARK: - CRC

    func testCrcIsCrc16ArcCheckValue() {
        // The nibble table is CRC-16/ARC; its catalogue check value over "123456789" is 0xBB3D.
        XCTAssertEqual(GarminGFDI.crc16(Array("123456789".utf8)), 0xBB3D)
    }

    func testCrcChainsAcrossChunks() {
        let a: [UInt8] = [1, 2, 3, 4], b: [UInt8] = [5, 6, 7]
        XCTAssertEqual(GarminGFDI.crc16(b, seed: GarminGFDI.crc16(a)), GarminGFDI.crc16(a + b))
    }

    // MARK: - COBS

    func testCobsWrapsAndEscapesZeros() {
        XCTAssertEqual(GarminGFDI.cobsEncode([0x11, 0x00, 0x22]), [0x00, 0x02, 0x11, 0x02, 0x22, 0x00])
        XCTAssertEqual(GarminGFDI.cobsEncode([0x11, 0x22, 0x00]), [0x00, 0x03, 0x11, 0x22, 0x01, 0x00])
        XCTAssertEqual(GarminGFDI.cobsEncode([]), [0x00, 0x01, 0x00])
    }

    func testCobsRoundTripIncludingLongRuns() {
        let samples: [[UInt8]] = [
            [0, 0, 0],
            Array(repeating: 0x5A, count: 300),
            (0..<600).map { UInt8($0 % 7) },
        ]
        for s in samples {
            let enc = GarminGFDI.cobsEncode(s)
            XCTAssertEqual(enc.first, 0); XCTAssertEqual(enc.last, 0)
            XCTAssertFalse(enc.dropFirst().dropLast().contains(0))
            XCTAssertEqual(GarminGFDI.cobsDecodeBody(Array(enc.dropFirst().dropLast())), s)
        }
    }

    func testAssemblerJoinsSplitChunksAndBackToBackFrames() {
        let f1 = GarminGFDI.cobsEncode([1, 0, 2]), f2 = GarminGFDI.cobsEncode([9, 9])
        var asm = GarminGFDI.CobsAssembler()
        XCTAssertEqual(asm.feed(Array(f1.prefix(3))), [])
        XCTAssertEqual(asm.feed(Array(f1.dropFirst(3)) + f2), [[1, 0, 2], [9, 9]])
    }

    // MARK: - Envelope

    func testSyncReadyFrameBytes() {
        // len 8, id 5030 (0x13A6), event 8, value 0, CRC-16/ARC over the first six bytes.
        XCTAssertEqual(hex(GarminGFDI.systemEvent(.syncReady)), "08 00 A6 13 08 00 D5 C5")
    }

    func testParseRejectsBadCrcAndExpandsCompactIds() {
        var f = GarminGFDI.frame(id: 5024, payload: [1, 2, 3])
        XCTAssertEqual(GarminGFDI.parse(f), GarminGFDI.Message(id: 5024, payload: [1, 2, 3]))
        f[4] ^= 0xFF
        XCTAssertNil(GarminGFDI.parse(f))
        // Compact form: bit 15 set, low byte + 5000.
        XCTAssertEqual(GarminGFDI.parse(GarminGFDI.frame(id: 0x8000 | 0x0300 | 24, payload: []))?.id, 5024)
    }

    // MARK: - Messages

    func testDeviceInformationParseAndReply() {
        var p: [UInt8] = [0x96, 0x00, 0x9B, 0x13, 0x01, 0x02, 0x03, 0x04, 0x40, 0x01, 0x77, 0x01]
        let cirqa: [UInt8] = Array("CIRQA".utf8)
        let model: [UInt8] = Array("abc".utf8)
        p.append(5); p.append(contentsOf: cirqa)
        p.append(5); p.append(contentsOf: cirqa)
        p.append(3); p.append(contentsOf: model)
        let info = GarminGFDI.parseDeviceInformation(p)
        XCTAssertEqual(info?.protocolVersion, 150)
        XCTAssertEqual(info?.productNumber, 5019)
        XCTAssertEqual(info?.unitNumber, 0x0403_0201)
        XCTAssertEqual(info?.softwareVersionString, "3.20")
        XCTAssertEqual(info?.maxPacketSize, 375)
        XCTAssertEqual(info?.model, "abc")

        let reply = GarminGFDI.parse(GarminGFDI.deviceInformationReply(
            to: info!, hostName: "N", manufacturer: "A", device: "i"))!
        XCTAssertEqual(reply.id, 5000)
        XCTAssertEqual(hex(Array(reply.payload.prefix(15))),
                       "A0 13 00 96 00 FF FF FF FF FF FF 6F 1E FF FF")
        XCTAssertEqual(Array(reply.payload.suffix(7)), [1, 0x4E, 1, 0x41, 1, 0x69, 1])
    }

    func testHostCapabilitiesBitset() {
        XCTAssertEqual(hex(GarminGFDI.hostCapabilities),
                       "FF FF 3F EF FF FF FF FF FF FF FF FF FF 00 03 FF 01")
    }

    func testCurrentTimeReply() {
        let req: [UInt8] = [0x0A, 0, 0, 0]
        let now = Date(timeIntervalSince1970: TimeInterval(631_065_600 + 0x0102_0304))
        let reply = GarminGFDI.parse(GarminGFDI.currentTimeReply(
            requestPayload: req, now: now, timeZone: TimeZone(secondsFromGMT: 3600)!)!)!
        XCTAssertEqual(hex(reply.payload),
                       "BC 13 00 0A 00 00 00 04 03 02 01 10 0E 00 00 00 00 00 00 00 00 00 00")
    }

    func testDownloadRequestAndStatus() {
        let f = GarminGFDI.downloadRequest(index: 0)
        XCTAssertEqual(f.count, 20)
        XCTAssertEqual(hex(Array(f[2..<18])), "8A 13 00 00 00 00 00 00 01 00 00 00 00 00 00 00")
        let ok = GarminGFDI.parseDownloadStatus([0x8A, 0x13, 0, 0, 0x20, 0x01, 0, 0])
        XCTAssertEqual(ok?.canProceed, true)
        XCTAssertEqual(ok?.fileSize, 0x120)
        XCTAssertEqual(GarminGFDI.parseDownloadStatus([0x8A, 0x13, 1])?.canProceed, false)
    }

    func testFileChunkAndAck() {
        let c = GarminGFDI.parseFileChunk([0x00, 0x34, 0x12, 0x10, 0, 0, 0, 0xAA, 0xBB])
        XCTAssertEqual(c, GarminGFDI.FileChunk(crc: 0x1234, offset: 16, data: [0xAA, 0xBB]))
        let ack = GarminGFDI.parse(GarminGFDI.fileChunkAck(nextOffset: 18))!
        XCTAssertEqual(hex(ack.payload), "8C 13 00 00 12 00 00 00")
    }

    func testDirectoryEntry() {
        let e: [UInt8] = [0x05, 0x00, 128, 49, 0x02, 0x00, 0x00, 0x00, 0x00, 0x10, 0, 0, 0x64, 0, 0, 0]
        let d = GarminGFDI.parseDirectory(e + [1, 2, 3])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].index, 5)
        XCTAssertEqual(d[0].kindName, "sleep")
        XCTAssertEqual(d[0].size, 0x1000)
        XCTAssertEqual(d[0].unixTimestamp, 631_065_600 + 100)
    }

    // MARK: - Multi-link

    func testHandleManagementBytes() {
        XCTAssertEqual(hex(GarminGFDI.closeAllRequest()), "00 05 02 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(hex(GarminGFDI.registerRequest(.gfdi)), "00 00 02 00 00 00 00 00 00 00 01 00 00")
        let resp: [UInt8] = [0x00, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0x06, 0x00, 0x00, 0x03, 0x00]
        XCTAssertEqual(GarminGFDI.parseHandleMessage(resp),
                       .registered(service: 6, status: 0, handle: 3, reliable: false))
        XCTAssertEqual(GarminGFDI.parseHandleMessage([0x00, 0x06, 0x02, 0, 0, 0, 0, 0, 0, 0]), .closeAllDone)
        XCTAssertNil(GarminGFDI.parseHandleMessage([0x00, 0x06, 0x09, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testChunksPrefixHandle() {
        XCTAssertEqual(GarminGFDI.chunks([1, 2, 3, 4, 5], handle: 7, maxWrite: 3), [[7, 1, 2], [7, 3, 4], [7, 5]])
    }

    func testRealtimeHR() {
        XCTAssertEqual(GarminGFDI.parseRealtimeHR([0, 72, 55])?.hr, 72)
        XCTAssertNil(GarminGFDI.parseRealtimeHR([0, 0, 55]))
    }

    func testMultiLinkUUIDs() {
        XCTAssertEqual(GarminGFDI.multiLinkNotifyUUID(0), "6A4E2810-667B-11E3-949A-0800200C9A66")
        XCTAssertEqual(GarminGFDI.multiLinkWriteUUID(4), "6A4E2824-667B-11E3-949A-0800200C9A66")
    }
}
