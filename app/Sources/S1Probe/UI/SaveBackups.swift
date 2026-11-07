// SPDX-License-Identifier: GPL-3.0-or-later
// Dishnur: a copy of every played Steam game's saves in a folder the player
// picks in Files (Settings › Downloads › Save backups). Playport keeps a
// bookmark to it. After a game is played (at the next start of Playport, and
// once Steam is signed in), its saves are copied to <folder>/<game>/
// (PlayportKit SaveBackupLayout): its Steam Cloud files, as Steam's rules
// for it name them, and the Steam emulator's folder for it. Each backup
// replaces the files the last one left; nothing is deleted from the folder.

import Combine
import Foundation
import PlayportKit
import SteamClientKit

@MainActor
final class SaveBackups: ObservableObject {
    static let shared = SaveBackups()

    static let bookmarkKey = "saves.backup.bookmark"
    /// When each title (by ID) was last backed up.
    static let stampsKey = "saves.backup.stamps"
    /// Settings' Choose the folder: the shell opens the Files picker (AppShell).
    static let requests = PassthroughSubject<Void, Never>()

    /// The picked folder's name; nil when none is picked.
    @Published private(set) var name: String?
    @Published private(set) var running = false
    /// What the last backup did, for Settings.
    @Published private(set) var last: String?

    private static func log(_ line: String) { SteamUILog.logger.info("save-backup", line) }

    private init() {
        if let url = Self.resolve() { name = url.lastPathComponent }
    }

    private static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        return url
    }

    /// What the Files picker returned for Choose the folder.
    func picked(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: Self.bookmarkKey)
            UserDefaults.standard.removeObject(forKey: Self.stampsKey)
            name = url.lastPathComponent
            Self.log("folder chosen: \(url.lastPathComponent)")
        } catch {
            Self.log("\(url.lastPathComponent): no bookmark: \(error)")
        }
        Task { await backUpPlayed() }
    }

    /// The folder is let go; the backups in it stay.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.stampsKey)
        name = nil
        last = nil
        Self.log("folder forgotten")
    }

    private static var stamps: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: stampsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: stampsKey) }
    }

    /// Every Steam game played since its last backup; `all` backs up every played one (Back up now).
    func backUpPlayed(all: Bool = false) async {
        guard name != nil, !running else { return }
        let due = LibraryModel.shared.catalog.titles.filter { t in
            t.store == .steam && t.appID != nil && t.lastPlayed != nil
                && (all || SaveBackupLayout.due(lastPlayed: t.lastPlayed,
                                                lastBackup: Self.stamps[t.id].map { Date(timeIntervalSince1970: $0) }))
        }
        guard !due.isEmpty else { return }
        guard let root = Self.resolve() else { last = "The folder cannot be found"; return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        running = true
        defer { running = false }
        var games = 0, files = 0
        for t in due {
            guard let n = await backUp(t, into: root) else { continue }
            Self.stamps[t.id] = Date().timeIntervalSince1970
            games += 1
            files += n
        }
        last = "\(games) game\(games == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s") · "
            + Date().formatted(date: .abbreviated, time: .shortened)
    }

    /// Copies one game's saves; the number of files, nil when its cloud rules cannot be read
    /// now (Steam not signed in yet: tried again later).
    private func backUp(_ t: InstalledTitle, into root: URL) async -> Int? {
        guard let app = t.appID else { return nil }
        let fm = FileManager.default
        let game = root.appendingPathComponent(SaveBackupLayout.folderName(t.displayName ?? t.name), isDirectory: true)
        var cloud: [String: URL] = [:]
        if let service = SteamAccountModel.current?.service {
            guard let files = await service.saveFiles(appID: app,
                                                      roots: LibraryModel.cloudRoots(appID: app, installDir: t.installDir))
            else { Self.log("\(t.name): Steam's save rules not read now; later"); return nil }
            cloud = files
        }
        var copied = 0
        for (name, src) in cloud.sorted(by: { $0.key < $1.key }) {
            guard let rel = SaveBackupLayout.path(forCloudName: name) else { continue }
            if copy(src, to: game.appendingPathComponent(rel)) { copied += 1 }
        }
        let emulator = EmulatorStats.folder(LibraryModel.emulatorSaves, appID: app)
        if let walk = fm.enumerator(at: emulator, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let src as URL in walk where (try? src.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let rel = String(src.standardizedFileURL.path.dropFirst(emulator.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if copy(src, to: game.appendingPathComponent(SaveBackupLayout.emulatorFolder, isDirectory: true)
                    .appendingPathComponent(rel)) { copied += 1 }
            }
        }
        Self.log("\(t.name): \(copied) file(s) to \(game.lastPathComponent)")
        return copied
    }

    private func copy(_ src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            return true
        } catch {
            Self.log("\(src.lastPathComponent): not copied: \(error.localizedDescription)")
            return false
        }
    }
}
