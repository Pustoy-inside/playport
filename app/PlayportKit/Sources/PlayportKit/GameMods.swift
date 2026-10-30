// SPDX-License-Identifier: GPL-3.0-or-later
// Files a person adds to an installed game (a game page's Add files and Run a
// program; the app's GameMods): a translation's archive or folder copied over
// the game's folder, an installer's .exe copied into it. What was added is
// recorded, so that an update or a repair, which may put the store's files
// back, asks first.

import Foundation
import SteamClientKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a person added to one game.
public struct GameModRecord: Codable, Equatable, Sendable {
    /// Paths under the game's folder, `/`-separated, as they are there.
    public var files: [String]
    /// The programs (.exe) copied into the game's folder to run.
    public var programs: [String]
    public var updatedAt: Date

    public init(files: [String] = [], programs: [String] = [], updatedAt: Date = Date()) {
        self.files = files
        self.programs = programs
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool { files.isEmpty && programs.isEmpty }

    /// `paths` added to `files`, each once without regard to case, sorted.
    public mutating func add(files paths: [String], at now: Date = Date()) {
        files = Self.merged(files, paths)
        updatedAt = now
    }

    public mutating func add(program name: String, at now: Date = Date()) {
        programs = Self.merged(programs, [name])
        files = Self.merged(files, [name])
        updatedAt = now
    }

    static func merged(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in a + b where seen.insert(p.lowercased()).inserted { out.append(p) }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// The records, by title ID, in one JSON file.
public struct GameModStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [String: GameModRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: GameModRecord].self, from: data)) ?? [:]
    }

    public func save(_ records: [String: GameModRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(records).write(to: url, options: .atomic)
    }
}

extension GameImporter {
    /// Copies `plan` over `dir`, an installed game's folder, replacing what is there. Each path
    /// goes where the game's folder already names it without regard to case (a translation's
    /// `data/text.pak` onto the game's `Data/Text.pak`), as Windows would. A zip's one folder at
    /// the top, or a picked folder, that the game's folder has too is that folder (a picked
    /// `Data`); any other is the translation's wrapper, left out. Returns the paths written, as
    /// they are in `dir`.
    public func merge(_ plan: ImportPlan, into dir: URL, progress: (Progress) -> Void = { _ in }) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.refused("the game's folder is not there")
        }
        try checkSpace(toCopy: plan.totalBytes)
        var names = CaselessNames()
        var prefix: [String] = []
        let top: String?
        switch plan.source {
        case let .folder(root): top = root.lastPathComponent
        case .zip: top = plan.strippedTop
        }
        if let top, let existing = try names.find(dir, top), existing.isDirectory { prefix = [existing.name] }
        var zip: ZipArchive?
        if case let .zip(u) = plan.source { zip = try ZipArchive(url: u) }
        let byPath = Dictionary((zip?.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var written: [String] = []
        var done: UInt64 = 0
        for (i, f) in plan.files.enumerated() {
            let parts = prefix + f.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ImportError.refused("\(f.path) is not a path inside the game's folder")
            }
            // The folders, each the game's own spelling where it has one.
            var at = dir, rel: [String] = []
            for part in parts.dropLast() {
                if let e = try names.find(at, part) {
                    guard e.isDirectory else { throw ImportError.refused("\((rel + [e.name]).joined(separator: "/")) is a file in the game") }
                    rel.append(e.name)
                    at = at.appendingPathComponent(e.name, isDirectory: true)
                } else {
                    at = at.appendingPathComponent(part, isDirectory: true)
                    try fm.createDirectory(at: at, withIntermediateDirectories: false)
                    names.added(at.deletingLastPathComponent(), part, isDirectory: true)
                    rel.append(part)
                }
            }
            let leaf = parts[parts.count - 1]
            var name = leaf
            if let e = try names.find(at, leaf) {
                guard !e.isDirectory else { throw ImportError.refused("\((rel + [e.name]).joined(separator: "/")) is a folder in the game") }
                name = e.name
            }
            let dst = at.appendingPathComponent(name)
            let part = at.appendingPathComponent(".\(name).part")
            try? fm.removeItem(at: part)
            switch plan.source {
            case let .folder(root):
                try Self.copy(root.appendingPathComponent(f.from), part) { _ in }
            case .zip:
                guard let zip, let e = byPath[f.from] else { throw ImportError.refused("\(f.from) is no longer in the archive") }
                try Self.write(part) { sink in try zip.extract(e) { buf in try sink(buf) } }
            }
            guard InstallFS.fileSize(part) == f.size else {
                try? fm.removeItem(at: part)
                throw ClientError.verificationFailed("\(f.path) copied as \(InstallFS.fileSize(part) ?? 0) bytes, not \(f.size)")
            }
            guard rename(part.path, dst.path) == 0 else { throw ClientError.transport("rename \(f.path) errno \(errno)") }
            names.added(at, name, isDirectory: false)
            written.append((rel + [name]).joined(separator: "/"))
            done += f.size
            progress(Progress(bytesDone: done, bytesTotal: plan.totalBytes, filesDone: i + 1, filesTotal: plan.files.count))
        }
        return written
    }

    /// Copies a program (`src`, an .exe) into `dir`, the game's folder, to run from there, as
    /// a translation's installer often must. A file of that name already in the folder is
    /// replaced only when `replacing`: a program copied before, not one of the game's.
    /// Returns its name in `dir`.
    public func copyProgram(_ src: URL, into dir: URL, replacing: Bool) throws -> String {
        let name = src.lastPathComponent
        do { try WindowsName.check(name) } catch { throw ImportError.refused("\(error)") }
        guard name.lowercased().hasSuffix(".exe") else { throw ImportError.refused("\(name) is not a Windows program (.exe)") }
        var names = CaselessNames()
        var target = name
        if let e = try names.find(dir, name) {
            guard !e.isDirectory, replacing else { throw ImportError.refused("the game's folder has a \(e.name) of its own") }
            target = e.name
        }
        let size = InstallFS.fileSize(src) ?? 0
        try checkSpace(toCopy: size)
        let part = dir.appendingPathComponent(".\(target).part")
        try? FileManager.default.removeItem(at: part)
        try Self.copy(src, part) { _ in }
        guard rename(part.path, dir.appendingPathComponent(target).path) == 0 else {
            throw ClientError.transport("rename \(target) errno \(errno)")
        }
        return target
    }
}

/// A folder's entries by lowercased name, listed once.
struct CaselessNames {
    struct Entry {
        var name: String
        var isDirectory: Bool
    }

    private var lists: [String: [String: Entry]] = [:]

    mutating func find(_ dir: URL, _ name: String) throws -> Entry? {
        let key = dir.standardizedFileURL.path
        if lists[key] == nil {
            var list: [String: Entry] = [:]
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                var st = stat()
                guard lstat(dir.appendingPathComponent(n).path, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                list[n.lowercased()] = Entry(name: n, isDirectory: kind == S_IFDIR)
            }
            lists[key] = list
        }
        return lists[key]?[name.lowercased()]
    }

    mutating func added(_ dir: URL, _ name: String, isDirectory: Bool) {
        lists[dir.standardizedFileURL.path, default: [:]][name.lowercased()] = Entry(name: name, isDirectory: isDirectory)
    }
}
