// SPDX-License-Identifier: GPL-3.0-or-later
// A game page's Add files and Run a program (PlayportKit GameMods): a
// translation's .zip or folder, picked in Files, copied over the game's folder;
// an installer's .exe copied into it and run there, in the game's prefix, as
// the game would be. What was added is recorded, and an update or a repair of
// the game asks first (they may put the store's files back); updates that
// Settings queue by themselves leave such a game alone.

import Combine
import Foundation
import PlayportKit
import SteamClientKit
import UniformTypeIdentifiers

@MainActor
final class GameMods: ObservableObject {
    static let shared = GameMods()

    /// What the shell's Files picker is for (AppShell).
    enum Pick: Equatable {
        case files(titleID: String)
        case program(titleID: String)

        var contentTypes: [UTType] {
            switch self {
            case .files: [.folder, .zip]
            case .program: [UTType(filenameExtension: "exe") ?? .data]
            }
        }
    }

    static let requests = PassthroughSubject<Pick, Never>()

    @Published private(set) var records: [String: GameModRecord]
    /// Games whose files are being copied now.
    @Published private(set) var copying: Set<String> = []

    private let store = GameModStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/mods.json"))

    private init() { records = store.load() }

    private static func log(_ line: String) { SteamUILog.logger.info("mods", line) }

    func record(_ id: String) -> GameModRecord? { records[id].flatMap { $0.isEmpty ? nil : $0 } }
    func has(_ id: String) -> Bool { record(id) != nil }

    /// The game's record goes (its page's Y on the row): updates no longer ask.
    func forget(_ id: String) {
        records[id] = nil
        save()
        Self.log("\(id): record forgotten")
    }

    private func save() {
        do { try store.save(records) } catch { Self.log("could not save the records: \(error)") }
    }

    private var importer: GameImporter { GameImporter(layout: LibraryModel.paths.layout) }

    /// What the Files picker returned for `pick`.
    func picked(_ url: URL, for pick: Pick) async {
        switch pick {
        case let .files(id): await addFiles(url, to: id)
        case let .program(id): await addProgram(url, to: id)
        }
    }

    private func folder(_ id: String) -> (InstalledTitle, URL)? {
        guard let t = LibraryModel.shared.catalog.title(id: id) else { return nil }
        return (t, LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true))
    }

    private func addFiles(_ url: URL, to id: String) async {
        guard let (t, dir) = folder(id) else { return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        let source: ImportSource
        if isDir {
            source = .folder(url)
        } else if url.pathExtension.lowercased() == "zip" {
            source = .zip(url)
        } else {
            return tell("Can't add \(url.lastPathComponent)", "Pick a folder or a .zip. Files unpacks other archives: "
                        + "tap one there, then pick the folder it makes.")
        }
        copying.insert(id)
        defer { copying.remove(id) }
        let importer = self.importer
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return Result { try importer.merge(try GameImporter.plan(source), into: dir) }
        }.value
        switch result {
        case let .success(written):
            records[id, default: GameModRecord()].add(files: written)
            save()
            Self.log("\(id): \(written.count) files from \(url.lastPathComponent)")
            tell("Added to \(t.name)", "\(written.count) file\(written.count == 1 ? "" : "s") from \(url.lastPathComponent) "
                 + "are in the game's folder, replacing the game's own where they had the same name.")
        case let .failure(e):
            Self.log("\(id): \(url.lastPathComponent) not added: \(e)")
            tell("Can't add \(url.lastPathComponent)", (e as? ImportError)?.description ?? "\(e)")
        }
    }

    private func addProgram(_ url: URL, to id: String) async {
        guard let (t, dir) = folder(id) else { return }
        let replacing = record(id)?.programs.contains { $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame } ?? false
        copying.insert(id)
        let importer = self.importer
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return Result { try importer.copyProgram(url, into: dir, replacing: replacing) }
        }.value
        copying.remove(id)
        switch result {
        case let .success(name):
            records[id, default: GameModRecord()].add(program: name)
            save()
            Self.log("\(id): program \(name) copied in")
            PadModal.shared.picker(
                title: "Run \(name)?", context: t.name,
                note: "It runs in \(t.name)'s folder (C:\\Games\\\(t.installDir)), where an installer finds the game. "
                    + "Playport restarts after it closes, as after a game.",
                options: [PadOption(id: "run", label: "Run"), PadOption(id: "later", label: "Not now",
                                                                      detail: "Run a program lists it again")],
                selected: "run") { choice in
                    if choice == "run" { self.run(name, in: id) }
                }
        case let .failure(e):
            Self.log("\(id): \(url.lastPathComponent) not copied: \(e)")
            tell("Can't run \(url.lastPathComponent)", (e as? ImportError)?.description ?? "\(e)")
        }
    }

    /// A program copied in before, run again.
    func run(_ name: String, in id: String) {
        Task {
            do {
                _ = try await LibraryModel.shared.play(id, program: name)
            } catch {
                Self.log("\(id): \(name) did not start: \(error)")
                tell("Can't run \(name)", "\(error)")
            }
        }
    }

    /// Before an update or a repair of a game with added files: what may happen, and a choice.
    func confirm(_ id: String, _ action: String, then go: @escaping () -> Void) {
        guard let r = record(id) else { return go() }
        PadModal.shared.picker(
            title: "\(action) may undo your files",
            note: "You added \(r.files.count) file\(r.files.count == 1 ? "" : "s") to this game (a translation?). "
                + "\(action) can put the store's own back over them; add them again after it if they are gone.",
            options: [PadOption(id: "go", label: action), PadOption(id: "cancel", label: "Cancel")],
            selected: "cancel") { if $0 == "go" { go() } }
    }

    private func tell(_ title: String, _ note: String) {
        PadModal.shared.picker(title: title, note: note, options: [PadOption(id: "ok", label: "OK")], selected: "ok") { _ in }
    }
}
