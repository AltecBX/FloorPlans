import Foundation

// MARK: - Minimal ZIP (store method) writer/reader
//
// Backs the .fieldplan portable package (spec §40). Entries are STORED, not
// deflated — the heavy assets (JPEG photos, USDZ) are already compressed, so
// deflate would buy little and cost a dependency. The format is standard ZIP,
// so packages open in Finder/Files and any archive tool.

public enum ZipError: Error, LocalizedError {
    case notAZipFile
    case unsupportedCompressionMethod(UInt16)
    case corruptArchive(String)

    public var errorDescription: String? {
        switch self {
        case .notAZipFile:
            return "The file is not a valid package."
        case .unsupportedCompressionMethod(let m):
            return "The package uses an unsupported compression method (\(m))."
        case .corruptArchive(let detail):
            return "The package is damaged: \(detail)"
        }
    }
}

public struct ZipEntry: Sendable {
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

public enum ZipArchive {

    // MARK: - CRC32

    static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Writing

    public static func write(entries: [ZipEntry], to url: URL) throws {
        let data = archiveData(entries: entries)
        try data.write(to: url, options: .atomic)
    }

    public static func archiveData(entries: [ZipEntry]) -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(truncatingIfNeeded: out.count)
            let size = UInt32(truncatingIfNeeded: entry.data.count)

            // Local file header.
            appendUInt32(&out, 0x0403_4B50)
            appendUInt16(&out, 20)         // version needed
            appendUInt16(&out, 0x0800)     // flags: UTF-8 names
            appendUInt16(&out, 0)          // method: store
            appendUInt16(&out, dosTime)
            appendUInt16(&out, dosDate)
            appendUInt32(&out, crc)
            appendUInt32(&out, size)
            appendUInt32(&out, size)
            appendUInt16(&out, UInt16(truncatingIfNeeded: nameBytes.count))
            appendUInt16(&out, 0)          // extra length
            out.append(nameBytes)
            out.append(entry.data)

            // Central directory record.
            appendUInt32(&central, 0x0201_4B50)
            appendUInt16(&central, 20)     // version made by
            appendUInt16(&central, 20)     // version needed
            appendUInt16(&central, 0x0800)
            appendUInt16(&central, 0)
            appendUInt16(&central, dosTime)
            appendUInt16(&central, dosDate)
            appendUInt32(&central, crc)
            appendUInt32(&central, size)
            appendUInt32(&central, size)
            appendUInt16(&central, UInt16(truncatingIfNeeded: nameBytes.count))
            appendUInt16(&central, 0)      // extra
            appendUInt16(&central, 0)      // comment
            appendUInt16(&central, 0)      // disk
            appendUInt16(&central, 0)      // internal attrs
            appendUInt32(&central, 0)      // external attrs
            appendUInt32(&central, offset)
            central.append(nameBytes)
            count += 1
        }

        let centralOffset = UInt32(truncatingIfNeeded: out.count)
        out.append(central)

        // End of central directory.
        appendUInt32(&out, 0x0605_4B50)
        appendUInt16(&out, 0)
        appendUInt16(&out, 0)
        appendUInt16(&out, count)
        appendUInt16(&out, count)
        appendUInt32(&out, UInt32(truncatingIfNeeded: central.count))
        appendUInt32(&out, centralOffset)
        appendUInt16(&out, 0)
        return out
    }

    // MARK: - Reading

    /// Reads all entries of a stored-method ZIP archive.
    public static func read(data: Data) throws -> [ZipEntry] {
        // Find end-of-central-directory record (search backwards; the record
        // is 22 bytes plus an optional comment up to 64 KB).
        let eocdSignature: UInt32 = 0x0605_4B50
        guard data.count >= 22 else { throw ZipError.notAZipFile }
        var eocdOffset = -1
        let searchStart = max(0, data.count - 22 - 65_536)
        var i = data.count - 22
        while i >= searchStart {
            if readUInt32(data, i) == eocdSignature {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        let entryCount = Int(readUInt16(data, eocdOffset + 10))
        let centralOffset = Int(readUInt32(data, eocdOffset + 16))

        var entries: [ZipEntry] = []
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  readUInt32(data, cursor) == 0x0201_4B50 else {
                throw ZipError.corruptArchive("central directory truncated")
            }
            let method = readUInt16(data, cursor + 10)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localOffset = Int(readUInt32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else {
                throw ZipError.corruptArchive("entry name truncated")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)

            guard method == 0 else { throw ZipError.unsupportedCompressionMethod(method) }

            // Parse local header for the actual data offset.
            guard localOffset + 30 <= data.count,
                  readUInt32(data, localOffset) == 0x0403_4B50 else {
                throw ZipError.corruptArchive("local header missing for \(name)")
            }
            let localNameLength = Int(readUInt16(data, localOffset + 26))
            let localExtraLength = Int(readUInt16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else {
                throw ZipError.corruptArchive("data truncated for \(name)")
            }
            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))

            // Verify CRC so corrupted packages fail loudly, not subtly.
            let expectedCRC = readUInt32(data, cursor + 16)
            guard crc32(payload) == expectedCRC else {
                throw ZipError.corruptArchive("checksum mismatch for \(name)")
            }

            entries.append(ZipEntry(path: name, data: payload))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    public static func read(url: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    // MARK: - Byte helpers

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, c.year ?? 1980)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: timeBits), UInt16(truncatingIfNeeded: dateBits))
    }
}
