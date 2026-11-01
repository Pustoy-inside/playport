// SPDX-License-Identifier: GPL-3.0-or-later
// An Inno Setup installer read without running it (the app's Add files, PlayportKit
// GameImporter.unpack): the
// files it puts in the folder it installs to ({app}), unpacked as they are stored. A
// translation's installer is often gigabytes in its own .exe, and Playport copies a program
// it runs whole into the JIT pool (at most 896 MiB): unpacked, its files are only data.
//
// The format, as innoextract (Daniel Scharrer, zlib licence) reads it, for setup data
// 5.5.0 to 6.4: the setup loader's table (at 0x30 or in resource 11111) gives where the
// headers and the files are; the headers are two LZMA blocks in 4 KiB pieces with a CRC32
// each (the setup header, its entries up to the files', then the files' data locations);
// the files are in chunks ("zlb\x1a", LZMA1, LZMA2, zlib or stored) at offsets into the
// data, an executable's CALL and JMP addresses relative (the 5200/5309 filter). Each file
// is checked against its stored SHA-1 (SHA-256 from 6.4). Not read: installers older than
// 5.5, encrypted files, bzip2, and data in setup-*.bin files beside the installer.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum InnoSetupError: Error, Equatable, CustomStringConvertible {
    case notInno
    case unsupported(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .notInno: "it is not an Inno Setup installer"
        case let .unsupported(why): "Playport can't unpack this installer: \(why)"
        case let .corrupt(why): "the installer's data is damaged (\(why))"
        }
    }
}

/// An installer's file, mapped read-only.
final class InnoMappedFile {
    let bytes: UnsafeRawBufferPointer

    init(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw InnoSetupError.corrupt("cannot open (errno \(errno))") }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 64 else { throw InnoSetupError.notInno }
        let size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw InnoSetupError.corrupt("cannot map (errno \(errno))")
        }
        bytes = UnsafeRawBufferPointer(start: p, count: size)
    }

    deinit { _ = munmap(UnsafeMutableRawPointer(mutating: bytes.baseAddress), bytes.count) }

    var count: Int { bytes.count }

    func u32(_ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// The first offset of `needle` in the first `within` bytes.
    func find(_ needle: [UInt8], within: Int) -> Int? {
        let end = min(count, within) - needle.count
        guard end >= 0 else { return nil }
        let first = needle[0]
        var i = 0
        while i <= end {
            if bytes[i] == first {
                var k = 1
                while k < needle.count, bytes[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

public struct InnoSetup {
    /// A version as Inno packs it: a.b.c.d, a byte each.
    public typealias Version = UInt32
    public static func version(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32 = 0) -> Version {
        a << 24 | b << 16 | c << 8 | d
    }

    public struct File: Equatable, Sendable {
        /// `{app}\Data\Text.pak` as the installer names it.
        public var destination: String
        public var location: Int
    }

    struct DataEntry {
        var chunkOffset: UInt64
        var offset: UInt64
        var size: UInt64
        var chunkSize: UInt64
        var sha1: [UInt8]?
        var sha256: [UInt8]?
        var callFilter: Bool
        var encrypted: Bool
        var compressed: Bool
    }

    /// The data version string: `Inno Setup Setup Data (5.5.7) (u)`.
    public let versionName: String
    public let version: Version
    public let unicode: Bool
    public let files: [File]
    let data: [DataEntry]
    let compression: Int
    let dataOffset: Int
    let file: InnoMappedFile

    /// The setup loader's magic numbers (5.1.5 and later; the second is Inno's own variant).
    static let loaderMagics: [[UInt8]] = [
        [0x72, 0x44, 0x6C, 0x50, 0x74, 0x53, 0xCD, 0xE6, 0xD7, 0x7B, 0x0B, 0x2A],
        [0x6E, 0x53, 0x35, 0x57, 0x37, 0x64, 0x54, 0x83, 0xAA, 0x1B, 0x0F, 0x6A],
    ]

    /// Whether `url` is an Inno Setup installer this reads, without throwing.
    public static func recognizes(_ url: URL) -> Bool { (try? InnoSetup(url)) != nil }

    public init(_ url: URL) throws {
        let file = try InnoMappedFile(url)
        let (headerOffset, dataOffset) = try Self.loaderOffsets(file)
        guard headerOffset + 64 <= file.count else { throw InnoSetupError.notInno }
        let name = String(decoding: UnsafeRawBufferPointer(rebasing: file.bytes[headerOffset..<(headerOffset + 64)])
            .prefix { $0 != 0 }, as: UTF8.self)
        guard name.contains("Inno Setup") else { throw InnoSetupError.notInno }
        let version = try Self.parseVersion(name)
        let unicode = version >= Self.version(6, 3, 0) || name.contains("(u)") || name.contains("(U)")
        guard version >= Self.version(5, 5, 0) else {
            throw InnoSetupError.unsupported("it was made with Inno Setup older than 5.5 (\(name))")
        }
        self.file = file
        self.dataOffset = dataOffset
        versionName = name
        self.version = version
        self.unicode = unicode
        let (first, next) = try Self.block(file, at: headerOffset + 64)
        var r = Reader(first, version: version, unicode: unicode)
        let (counts, compression) = try Self.header(&r)
        self.compression = compression
        for _ in 0..<counts.languages { try Self.skipLanguage(&r) }
        for _ in 0..<counts.messages { try r.strings(2); try r.skip(4) }
        for _ in 0..<counts.permissions { try r.strings(1) }
        for _ in 0..<counts.types { try r.strings(4); try r.winver(); try r.flags(1); try r.skip(1 + 8) }
        for _ in 0..<counts.components {
            try r.strings(5); try r.skip(8 + 4 + 1); try r.winver(); try r.flags(5); try r.skip(8)
        }
        for _ in 0..<counts.tasks { try r.strings(6); try r.skip(4 + 1); try r.winver(); try r.flags(5) }
        for _ in 0..<counts.directories {
            try r.strings(1); try r.strings(6); try r.skip(4); try r.winver(); try r.skip(2); try r.flags(5)
        }
        var files: [File] = []
        files.reserveCapacity(counts.files)
        for _ in 0..<counts.files {
            try r.strings(1)   // source
            let dest = try r.string()
            try r.strings(2)   // font name, strong assembly name
            try r.strings(6)   // components, tasks, languages, check, after install, before install
            try r.winver()
            let location = try r.u32()
            try r.skip(4 + 8 + 2)   // attributes, external size, permission
            try r.flags(Self.fileFlagCount)
            let type = try r.u8()
            // An uninstaller (type 1) and an external file (no location) are not in the data.
            if type == 0, location != UInt32.max { files.append(File(destination: dest, location: Int(location))) }
        }
        self.files = files
        let (second, _) = try Self.block(file, at: next)
        var d = Reader(second, version: version, unicode: unicode)
        var data: [DataEntry] = []
        data.reserveCapacity(counts.data)
        for _ in 0..<counts.data { data.append(try Self.dataEntry(&d, version: version)) }
        guard d.at == second.count else {
            throw InnoSetupError.unsupported("its file table is not one this reads (\(name))")
        }
        self.data = data
        for f in files where f.location >= data.count {
            throw InnoSetupError.corrupt("file \(f.destination) has no data")
        }
    }

    // MARK: the loader and the header blocks

    static func loaderOffsets(_ f: InnoMappedFile) throws -> (header: Int, data: Int) {
        var table: Int?
        if f.count > 0x3C, f.u32(0x30) == 0x6F6E_6E49 {   // "Inno"
            let at = f.u32(0x34), not = f.u32(0x38)
            if at == ~not { table = Int(at) }
        }
        if table == nil {
            // The loader's table is resource 11111, near the start of the installer.
            for m in loaderMagics { if let i = f.find(m, within: 32 << 20) { table = i; break } }
        }
        guard let t = table, t + 12 + 4 * 8 <= f.count,
              loaderMagics.contains(where: { m in m.indices.allSatisfy { f.bytes[t + $0] == m[$0] } })
        else { throw InnoSetupError.notInno }
        // revision, first, exe offset, exe size, exe CRC, header offset, data offset, table CRC
        let header = Int(f.u32(t + 12 + 4 * 5)), data = Int(f.u32(t + 12 + 4 * 6))
        guard header < f.count, data < f.count else { throw InnoSetupError.notInno }
        return (header, data)
    }

    static func parseVersion(_ name: String) throws -> Version {
        var best: Version = 0
        var rest = Substring(name)
        while let open = rest.firstIndex(of: "(") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: ")") else { break }
            let parts = after[..<close].split(separator: ".").compactMap { UInt32($0) }
            if parts.count == 3 || parts.count == 4, parts.allSatisfy({ $0 < 256 }),
               after[..<close].split(separator: ".").count == parts.count {
                best = max(best, version(parts[0], parts[1], parts[2], parts.count == 4 ? parts[3] : 0))
            }
            rest = after[close...]
        }
        guard best > 0 else { throw InnoSetupError.unsupported("unknown setup data \(name)") }
        return best
    }

    /// A block of headers at `at`: its bytes, and where the next block starts.
    static func block(_ f: InnoMappedFile, at: Int) throws -> ([UInt8], Int) {
        guard at + 9 <= f.count else { throw InnoSetupError.corrupt("headers end early") }
        let expect = f.u32(at)
        let stored = Int(f.u32(at + 4))
        let compressed = f.bytes[at + 8] != 0
        guard CRC32.update(0, UnsafeRawBufferPointer(rebasing: f.bytes[(at + 4)..<(at + 9)])) == expect else {
            throw InnoSetupError.corrupt("header block checksum")
        }
        guard at + 9 + stored <= f.count else { throw InnoSetupError.corrupt("headers end early") }
        var raw: [UInt8] = []
        raw.reserveCapacity(stored)
        var i = at + 9
        let end = at + 9 + stored
        while i < end {
            guard i + 4 < end else { throw InnoSetupError.corrupt("header piece") }
            let crc = f.u32(i)
            let piece = UnsafeRawBufferPointer(rebasing: f.bytes[(i + 4)..<min(i + 4 + 4096, end)])
            guard CRC32.update(0, piece) == crc else { throw InnoSetupError.corrupt("header piece checksum") }
            raw.append(contentsOf: piece)
            i += 4 + piece.count
        }
        guard compressed else { return (raw, end) }
        var out: [UInt8] = []
        try raw.withUnsafeBytes { buf in
            try InnoLZMA.decodeLZMA1(buf, limit: UInt64.max) { out.append(contentsOf: $0) }
        }
        return (out, end)
    }

    struct Counts {
        var languages = 0, messages = 0, permissions = 0, types = 0, components = 0, tasks = 0
        var directories = 0, files = 0, data = 0
    }

    /// The setup header: the counts of the entries after it and the files' compression
    /// (0 stored, 1 zlib, 2 bzip2, 3 LZMA1, 4 LZMA2).
    static func header(_ r: inout Reader) throws -> (Counts, Int) {
        let v = r.version
        // App name to compiled code: the 31 strings of 5.5.0, and those added since.
        var n = 31
        if v >= version(5, 5, 6) { n += 1 }   // setup mutex
        if v >= version(5, 6, 1) { n += 2 }   // changes environment, changes associations
        if v >= version(6, 3, 0) { n += 2 }   // the architectures' expressions
        try r.strings(n)
        if !r.unicode { try r.skip(32) }   // lead bytes
        var c = Counts()
        c.languages = Int(try r.u32()); c.messages = Int(try r.u32()); c.permissions = Int(try r.u32())
        c.types = Int(try r.u32()); c.components = Int(try r.u32()); c.tasks = Int(try r.u32())
        c.directories = Int(try r.u32()); c.files = Int(try r.u32()); c.data = Int(try r.u32())
        for _ in 0..<7 { _ = try r.u32() }   // icons, ini, registry, deletes, uninstall deletes, runs, uninstall runs
        try r.winver()
        if v < version(6, 4, 0, 1) { try r.skip(8) }    // back colours
        if v < version(5, 5, 7) { try r.skip(4) }       // image back colour
        if v >= version(6, 0, 0) { try r.skip(1 + 8) }  // wizard style, resize percentages
        if v >= version(5, 5, 7) { try r.skip(1) }      // image alpha format
        try r.skip(v >= version(6, 4, 0) ? 4 + 44 : 20 + 8)   // password hash, salt
        try r.skip(8 + 4 + 1 + 1 + 1)   // extra disk space, slices per disk, uninstall log mode, dir exists warning, privileges
        if v >= version(5, 7, 0) { try r.skip(1) }      // privileges override
        try r.skip(2)                                   // language dialog, language detection
        let compression = Int(try r.u8())
        if v < version(6, 3, 0) { try r.skip(2) }       // architectures
        try r.skip(2 + 8)   // dir and program group pages, uninstall display size
        if v == version(5, 5, 0, 1) { try r.skip(1) }
        try r.flags(headerFlagCount(v, unicode: r.unicode))
        return (c, compression)
    }

    static func headerFlagCount(_ v: Version, unicode: Bool) -> Int {
        var n = 5   // startup prompt, create app dir, allow no icons, always restart, personal group
        if v < version(6, 4, 0, 1) { n += 4 }   // window flags
        n += 4      // dir doesn't exist warning, password, allow root directory, disable finished page
        if v < version(5, 6, 1) { n += 1 }      // changes associations
        n += 1      // use previous app dir
        if v < version(6, 4, 0, 1) { n += 1 }   // back colour horizontal
        n += 3      // use previous group, update uninstall log app name, use previous setup type
        n += 6 + 2  // ready memo .. ready page; dir and group on ready page
        n += 1 + 2 + 1 + 1       // UNC path, user info page ×2, uninstall restart, restart if needed by run
        n += 1 + 1 + 1 + 2 + 1   // tasks tree lines, cancel during install, image stretch, append ×2, encryption
        if v < version(5, 6, 1) { n += 1 }      // changes environment
        if !unicode { n += 1 }                  // show undisplayable languages
        n += 4      // setup logging, signed uninstaller, use previous language, disable welcome page
        n += 3      // close applications, restart applications, allow network drive
        if v >= version(5, 5, 7) { n += 1 }     // force close applications
        if v >= version(6, 0, 0) { n += 3 }
        if v >= version(6, 3, 0) { n += 1 }     // uninstall logging
        return n
    }

    static let fileFlagCount = 32

    static func skipLanguage(_ r: inout Reader) throws {
        try r.strings(2)   // name, language name
        if r.version == version(5, 5, 7, 1) { try r.strings(1) }
        try r.strings(4 + 1 + 3)   // fonts, data, license, info before, info after
        try r.skip(4)              // language id
        if !r.unicode { try r.skip(4) }   // code page
        try r.skip(16)             // font sizes
        if r.version == version(5, 5, 7, 1) { try r.skip(4) }
        try r.skip(1)              // right to left
    }

    static func dataEntry(_ r: inout Reader, version v: Version) throws -> DataEntry {
        try r.skip(8)   // first and last slice
        let chunkOffset = UInt64(try r.u32())
        let offset = try r.u64(), size = try r.u64(), chunkSize = try r.u64()
        var sha1: [UInt8]?, sha256: [UInt8]?
        if v >= version(6, 4, 0) { sha256 = try r.bytes(32) } else { sha1 = try r.bytes(20) }
        try r.skip(8 + 8)   // file time, file version
        var nflags = 9
        if v >= version(5, 5, 7), v < version(6, 3, 0) { nflags += 2 }
        let nbytes = (nflags + 7) / 8
        let fb = try r.bytes(nbytes)
        if nbytes == 3 { try r.skip(1) }
        var bits = 0
        for (i, b) in fb.enumerated() { bits |= Int(b) << (8 * i) }
        if v >= version(6, 3, 0) { try r.skip(1) }   // sign mode
        // version info valid, not valid, UTC, uninstaller, call filter, touch, encrypted, compressed, solid break
        return DataEntry(chunkOffset: chunkOffset, offset: offset, size: size, chunkSize: chunkSize, sha1: sha1,
                         sha256: sha256, callFilter: bits & (1 << 4) != 0, encrypted: bits & (1 << 6) != 0,
                         compressed: bits & (1 << 7) != 0)
    }

    struct Reader {
        let b: [UInt8]
        var at = 0
        let version: Version
        let unicode: Bool

        init(_ b: [UInt8], version: Version, unicode: Bool) {
            self.b = b
            self.version = version
            self.unicode = unicode
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, at + n <= b.count else { throw InnoSetupError.corrupt("headers end early") }
            at += n
        }

        mutating func u8() throws -> UInt8 {
            try skip(1)
            return b[at - 1]
        }

        mutating func u32() throws -> UInt32 {
            try skip(4)
            return UInt32(b[at - 4]) | UInt32(b[at - 3]) << 8 | UInt32(b[at - 2]) << 16 | UInt32(b[at - 1]) << 24
        }

        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32())
            return lo | UInt64(try u32()) << 32
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            try skip(n)
            return Array(b[(at - n)..<at])
        }

        mutating func strings(_ n: Int) throws {
            for _ in 0..<n { try skip(Int(try u32())) }
        }

        /// A string as the installer stores it: UTF-16 in a Unicode one, else Windows-1252.
        mutating func string() throws -> String {
            let raw = try bytes(Int(try u32()))
            if unicode {
                let units = stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            }
            return String(raw.map { Character(Unicode.Scalar($0)) })
        }

        /// A windows_version_range: two versions of 10 bytes.
        mutating func winver() throws { try skip(20) }

        /// `n` flags stored as a Delphi set: whole bytes, 3 padded to 4.
        mutating func flags(_ n: Int) throws {
            let bytes = (n + 7) / 8
            try skip(bytes + (bytes == 3 ? 1 : 0))
        }
    }

    // MARK: the files

    /// `{app}\Data\Text.pak` → `Data/Text.pak`; nil for a file put anywhere else ({tmp}, {sys},
    /// a path with another constant) or one that would leave the folder.
    public static func appPath(_ destination: String) -> String? {
        let prefix = "{app}\\"
        guard destination.count > prefix.count, destination.lowercased().hasPrefix(prefix) else { return nil }
        let parts = destination.dropFirst(prefix.count).split(separator: "\\", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("{") && !$0.contains("/")
            && !$0.contains(":") }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The files this puts in its folder, and their size in all.
    public var appFiles: (count: Int, bytes: UInt64) {
        var n = 0, total: UInt64 = 0
        for f in files where Self.appPath(f.destination) != nil {
            n += 1
            total += data[f.location].size
        }
        return (n, total)
    }

    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64

        public init(bytesDone: UInt64, bytesTotal: UInt64) {
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }
    }

    /// Unpacks the files under {app} into `dir` (made if needed), each checked against its
    /// stored hash. Returns their paths under `dir`, `/`-separated, in the installer's order.
    public func extract(into dir: URL, progress: @escaping (Progress) -> Void = { _ in }) throws -> [String] {
        // A path the installer writes twice (another component's or language's file) is its
        // last file's.
        var last: [String: (path: String, location: Int)] = [:]
        var order: [String] = []
        for f in files {
            guard let p = Self.appPath(f.destination) else { continue }
            if last[p.lowercased()] == nil { order.append(p.lowercased()) }
            last[p.lowercased()] = (p, f.location)
        }
        var wanted: [Int: [String]] = [:]   // data entry -> paths under dir
        for (_, v) in last { wanted[v.location, default: []].append(v.path) }
        guard !wanted.isEmpty else { throw InnoSetupError.unsupported("it puts no files in the game's folder") }
        guard dataOffset != 0 else {
            throw InnoSetupError.unsupported("its files are in setup-1.bin files beside it, not in the .exe")
        }
        // Chunks in the order they are in the installer; each data entry in it by offset.
        let byChunk = Dictionary(grouping: wanted.keys) { data[$0].chunkOffset }
        let total = wanted.keys.reduce(UInt64(0)) { $0 + data[$1].size }
        var done: UInt64 = 0
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for chunk in byChunk.keys.sorted() {
            let entries = byChunk[chunk]!.sorted { data[$0].offset < data[$1].offset }
            try extractChunk(at: chunk, entries: entries, wanted: wanted, into: dir) { n in
                done += n
                progress(Progress(bytesDone: done, bytesTotal: total))
            }
        }
        return order.compactMap { last[$0]?.path }
    }

    private func extractChunk(at chunkOffset: UInt64, entries: [Int], wanted: [Int: [String]], into dir: URL,
                              tick: @escaping (UInt64) -> Void) throws {
        let first = data[entries[0]]
        guard !first.encrypted else { throw InnoSetupError.unsupported("its files are encrypted with a password") }
        let start = dataOffset + Int(chunkOffset)
        guard start + 4 + Int(first.chunkSize) <= file.count,
              file.bytes[start] == 0x7A, file.bytes[start + 1] == 0x6C, file.bytes[start + 2] == 0x62,
              file.bytes[start + 3] == 0x1A else { throw InnoSetupError.corrupt("chunk at \(chunkOffset)") }
        let raw = UnsafeRawBufferPointer(rebasing: file.bytes[(start + 4)..<(start + 4 + Int(first.chunkSize))])
        let limit = entries.map { data[$0].offset + data[$0].size }.max() ?? 0

        // The chunk's bytes, as they come out, to the files they belong to.
        var outputs = try entries.map { e in try ChunkFile(entry: data[e], paths: wanted[e]!, under: dir,
                                                           flip: version >= Self.version(5, 3, 9)) }
        defer { for o in outputs { o.close() } }
        var pos: UInt64 = 0
        var next = 0
        let sink: InnoSink = { buf in
            var b = buf
            while !b.isEmpty {
                // Bytes before the next file are skipped; then the file's.
                while next < outputs.count, outputs[next].remaining == 0 { next += 1 }
                guard next < outputs.count else { return }
                let o = outputs[next]
                if pos < o.entry.offset {
                    let skip = Int(min(UInt64(b.count), o.entry.offset - pos))
                    b = UnsafeRawBufferPointer(rebasing: b[skip...])
                    pos += UInt64(skip)
                    continue
                }
                guard pos == o.entry.offset + (o.entry.size - o.remaining) else {
                    throw InnoSetupError.corrupt("files overlap in a chunk")
                }
                let n = Int(min(UInt64(b.count), o.remaining))
                try o.write(UnsafeRawBufferPointer(rebasing: b[..<n]))
                tick(UInt64(n))
                b = UnsafeRawBufferPointer(rebasing: b[n...])
                pos += UInt64(n)
            }
        }
        switch first.compressed ? compression : 0 {
        case 0:
            guard UInt64(raw.count) >= limit else { throw InnoSetupError.corrupt("stored chunk too short") }
            try sink(UnsafeRawBufferPointer(rebasing: raw[..<Int(limit)]))
        case 1:
            guard raw.count > 2 else { throw InnoSetupError.corrupt("zlib chunk") }
            var given = false
            var inflate = InflateStream(limit: limit, read: {
                if given { return nil }
                given = true
                return Array(raw[2...])
            }, write: { try sink($0) })
            do { try inflate.run() } catch ClientError.unsafeContent(_) where inflate.produced >= limit {}
        case 3:
            try InnoLZMA.decodeLZMA1(raw, limit: limit, sink: sink)
        case 4:
            try InnoLZMA.decodeLZMA2(raw, limit: limit, sink: sink)
        case 2:
            throw InnoSetupError.unsupported("its files are compressed with bzip2")
        default:
            throw InnoSetupError.unsupported("unknown compression \(compression)")
        }
        for o in outputs {
            guard o.remaining == 0 else { throw InnoSetupError.corrupt("a file ends early") }
            try o.finish()
        }
        outputs.removeAll()
    }
}

/// One data entry's bytes on their way out: through the CALL filter when it has it, into
/// its hash and every file it is (several files can share one entry).
private final class ChunkFile {
    let entry: InnoSetup.DataEntry
    private(set) var remaining: UInt64
    private var fds: [Int32] = []
    private var sha1 = SHA1Stream()
    private var sha256 = SHA256Stream()
    private var filter: InnoCallFilter?
    private let names: [String]

    init(entry: InnoSetup.DataEntry, paths: [String], under dir: URL, flip: Bool) throws {
        self.entry = entry
        remaining = entry.size
        names = paths
        if entry.callFilter { filter = InnoCallFilter(flip: flip) }
        for p in Set(paths) {
            let url = dir.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw InnoSetupError.corrupt("cannot create \(p) (errno \(errno))") }
            fds.append(fd)
        }
    }

    func write(_ buf: UnsafeRawBufferPointer) throws {
        remaining -= UInt64(buf.count)
        if var f = filter {
            try f.process(buf, end: remaining == 0) { try out($0) }
            filter = f
        } else {
            try out(buf)
        }
    }

    private func out(_ buf: UnsafeRawBufferPointer) throws {
        if entry.sha256 != nil { sha256.update(buf) } else { sha1.update(buf) }
        for fd in fds {
            var off = 0
            while off < buf.count {
                let n = Darwin_or_Glibc_write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    if errno == ENOSPC { throw ClientError.insufficientSpace(needed: UInt64(buf.count - off), available: 0) }
                    throw InnoSetupError.corrupt("write \(names.first ?? "") errno \(errno)")
                }
                off += n
            }
        }
    }

    func finish() throws {
        let ok = entry.sha256.map { $0 == sha256.finalize() } ?? (entry.sha1.map { $0 == sha1.finalize() } ?? true)
        guard ok else { throw InnoSetupError.corrupt("\(names.first ?? "a file") does not match its checksum") }
    }

    func close() {
        for fd in fds { _ = Darwin_or_Glibc_close(fd) }
        fds.removeAll()
    }
}

@inline(__always) private func Darwin_or_Glibc_write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, p, n)
    #else
    return Darwin.write(fd, p, n)
    #endif
}

@inline(__always) private func Darwin_or_Glibc_close(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.close(fd)
    #else
    return Darwin.close(fd)
    #endif
}

/// Inno's CALL and JMP filter undone (5.2.0 and later; `flip` from 5.3.9): the address after
/// an E8 or E9 byte made relative again, unless the instruction crosses a 64 KiB block or its
/// high byte is not 00 or FF.
public struct InnoCallFilter {
    let flip: Bool
    private var offset: UInt32 = 0
    private var pending: [UInt8] = []
    private var collecting = 0

    public init(flip: Bool) { self.flip = flip }

    public mutating func process(_ buf: UnsafeRawBufferPointer, end: Bool, emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        var out = [UInt8]()
        out.reserveCapacity(buf.count + 4)
        for byte in buf {
            offset &+= 1
            if collecting > 0 {
                pending.append(byte)
                collecting -= 1
                if collecting == 0 {
                    if pending[3] == 0x00 || pending[3] == 0xFF {
                        let addr = offset & 0xFF_FFFF
                        let rel = (UInt32(pending[0]) | UInt32(pending[1]) << 8 | UInt32(pending[2]) << 16) &- addr
                        pending[0] = UInt8(truncatingIfNeeded: rel)
                        pending[1] = UInt8(truncatingIfNeeded: rel >> 8)
                        pending[2] = UInt8(truncatingIfNeeded: rel >> 16)
                        if flip, rel & 0x80_0000 != 0 { pending[3] = ~pending[3] }
                    }
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
                continue
            }
            out.append(byte)
            if byte == 0xE8 || byte == 0xE9, 0x10000 - ((offset - 1) % 0x10000) >= 5 {
                collecting = 4
            }
        }
        if end, collecting > 0 {
            out.append(contentsOf: pending)
            pending.removeAll()
            collecting = 0
        }
        try out.withUnsafeBytes { try emit($0) }
    }
}
