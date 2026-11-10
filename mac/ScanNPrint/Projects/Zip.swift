import Compression
import Foundation

/// Just enough of the zip format for .snp projects: stored and deflated entries, no zip64.
/// Compatible with the files written by the Windows app (System.IO.Compression).
struct ZipError: Error {
    let message: String
}

final class ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ZipError(message: "Couldn't create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    deinit { try? handle.close() }

    func add(name: String, data: Data, compress: Bool) throws {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        var payload = data
        var method: UInt16 = 0
        if compress, !data.isEmpty, let deflated = Deflate.compress(data), deflated.count < data.count {
            payload = deflated
            method = 8
        }
        guard data.count < Int(UInt32.max), offset + UInt64(payload.count) + 1024 < UInt64(UInt32.max) else {
            throw ZipError(message: "The project is too large to save.")
        }
        var header = Data()
        header.append32(0x0403_4B50)
        header.append16(20)
        header.append16(0x0800) // UTF-8 names
        header.append16(method)
        header.append16(dosTime)
        header.append16(dosDate)
        header.append32(crc)
        header.append32(UInt32(payload.count))
        header.append32(UInt32(data.count))
        header.append16(UInt16(nameBytes.count))
        header.append16(0)
        header.append(contentsOf: nameBytes)
        try write(header)
        entries.append(Entry(name: nameBytes, crc: crc, compressedSize: UInt32(payload.count), size: UInt32(data.count),
                             method: method, offset: UInt32(offset - UInt64(header.count))))
        try write(payload)
    }

    func finish() throws {
        let start = offset
        var directory = Data()
        for e in entries {
            directory.append32(0x0201_4B50)
            directory.append16(20)
            directory.append16(20)
            directory.append16(0x0800)
            directory.append16(e.method)
            directory.append16(dosTime)
            directory.append16(dosDate)
            directory.append32(e.crc)
            directory.append32(e.compressedSize)
            directory.append32(e.size)
            directory.append16(UInt16(e.name.count))
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append32(0)
            directory.append32(e.offset)
            directory.append(contentsOf: e.name)
        }
        let directorySize = UInt32(directory.count)
        directory.append32(0x0605_4B50)
        directory.append16(0)
        directory.append16(0)
        directory.append16(UInt16(entries.count))
        directory.append16(UInt16(entries.count))
        directory.append32(directorySize)
        directory.append32(UInt32(start))
        directory.append16(0)
        try write(directory)
        try handle.synchronize()
        try handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

final class ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 22 else { throw ZipError(message: "Not a zip file.") }
        var end = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while i >= lowest {
            if data.u32(i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ZipError(message: "Not a zip file.") }
        let count = Int(data.u16(end + 10))
        var p = Int(data.u32(end + 16))
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { throw ZipError(message: "Damaged zip directory.") }
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            let compressed = data.u32(p + 20), size = data.u32(p + 24)
            let nameLength = Int(data.u16(p + 28)), extraLength = Int(data.u16(p + 30)), commentLength = Int(data.u16(p + 32))
            let local = data.u32(p + 42)
            guard compressed != .max, size != .max, local != .max else { throw ZipError(message: "Zip64 isn't supported.") }
            guard p + 46 + nameLength <= data.count else { throw ZipError(message: "Damaged zip directory.") }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, crc: crc, compressedSize: Int(compressed), size: Int(size),
                                  localHeaderOffset: Int(local))
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func read(_ entry: Entry) throws -> Data {
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { throw ZipError(message: "Damaged zip entry.") }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError(message: "Damaged zip entry.") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        let out: Data
        switch entry.method {
        case 0: out = raw
        case 8:
            guard let inflated = Deflate.decompress(raw, size: entry.size) else { throw ZipError(message: "Damaged zip entry.") }
            out = inflated
        default: throw ZipError(message: "Unsupported zip compression.")
        }
        guard out.count == entry.size, CRC32.checksum(out) == entry.crc else { throw ZipError(message: "Damaged zip entry.") }
        return out
    }
}

/// Raw deflate (RFC 1951), which is what zip uses and what Apple's COMPRESSION_ZLIB produces.
enum Deflate {
    static func compress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    static func decompress(_ data: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        guard !data.isEmpty else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for b in bytes { crc = t[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
}
