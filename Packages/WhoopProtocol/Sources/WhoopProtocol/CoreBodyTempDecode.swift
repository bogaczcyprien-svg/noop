import Foundation

// MARK: - CORE body-temperature sensor pure decoder
//
// Field parsing for the Core Body Temperature characteristic of the CORE sensor (greenteg), published
// openly as "CORE SENSOR - Core Body Temperature Service Specification" V2.2
// (github.com/CoreBodyTemp/CoreBodyTemp):
//
//   • Core Body Temperature service      00002100-5B1E-4347-B07C-97B514DAE121
//   • Core Body Temperature characteristic 00002101-5B1E-4347-B07C-97B514DAE121 (notify, ~1 Hz)
//
// Payload, little endian, fields after the flags present only when their flag bit is set:
//   flags (u8) · core temperature (s16, 0.01 °C/°F, mandatory) · skin temperature (s16, bit 0)
//   · core reserved (s16, bit 1) · quality and state (u8, bit 2) · heart rate (u8 bpm, bit 4)
//   · heat strain index (u8, 0.1 a.u., bit 5). Bit 3 selects °F instead of °C.
// A core value of 0x7FFF means "data not available" (sensor off body or still settling).
//
// NOOP only READS this characteristic. The service's control point (00002102, heart-rate pairing) is
// never written.
//
// SECURITY / ROBUSTNESS: the buffer is UNTRUSTED BLE input. Every read is bounds-checked; a packet too
// short for its mandatory core field yields nil, and a truncated optional field is left unset.

/// One decoded CORE reading. Temperatures are always in °C, whatever unit the sensor sent.
public struct CoreBodyTempReading: Sendable, Equatable {
    /// Core (internal) body temperature, °C. nil when the sensor reports "data not available".
    public let coreC: Double?
    /// Skin temperature at the sensor, °C, when sent.
    public let skinC: Double?
    /// Data quality, 0 invalid · 1 poor · 2 fair · 3 good · 4 excellent; nil when not sent or N/A.
    public let quality: Int?
    /// Heart rate the sensor itself receives from a paired strap, bpm; nil when absent or 0.
    public let heartRate: Int?
    /// CORE Heat Strain Index (0 – 25.4), when sent.
    public let heatStrainIndex: Double?
}

public enum CoreBodyTempDecode {

    public static let serviceUUID = "00002100-5B1E-4347-B07C-97B514DAE121"
    public static let temperatureCharacteristicUUID = "00002101-5B1E-4347-B07C-97B514DAE121"

    /// The raw "data not available" core value.
    static let notAvailable: Int16 = 0x7FFF

    /// Decode one Core Body Temperature notification, or nil when it is too short to hold a core value.
    public static func parse(_ bytes: [UInt8]) -> CoreBodyTempReading? {
        guard bytes.count >= 3 else { return nil }
        let flags = bytes[0]
        let fahrenheit = flags & 0x08 != 0
        var i = 1

        func s16() -> Int16? {
            guard i + 1 < bytes.count else { i = bytes.count; return nil }
            defer { i += 2 }
            return Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
        }
        func u8() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }
        func celsius(_ raw: Int16) -> Double {
            let v = Double(raw) / 100.0
            return fahrenheit ? (v - 32.0) * 5.0 / 9.0 : v
        }

        guard let coreRaw = s16() else { return nil }
        let core = coreRaw == notAvailable ? nil : celsius(coreRaw)

        var skin: Double?
        if flags & 0x01 != 0, let raw = s16(), raw != notAvailable { skin = celsius(raw) }
        if flags & 0x02 != 0 { _ = s16() }
        var quality: Int?
        if flags & 0x04 != 0, let q = u8() {
            let level = Int(q & 0x07)
            quality = level <= 4 ? level : nil
        }
        var heartRate: Int?
        if flags & 0x10 != 0, let hr = u8(), hr > 0 { heartRate = Int(hr) }
        var hsi: Double?
        if flags & 0x20 != 0, let h = u8(), h != 0xFF { hsi = Double(h) / 10.0 }

        return CoreBodyTempReading(coreC: core, skinC: skin, quality: quality,
                                   heartRate: heartRate, heatStrainIndex: hsi)
    }
}
