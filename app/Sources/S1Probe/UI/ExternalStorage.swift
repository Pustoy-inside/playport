// SPDX-License-Identifier: GPL-3.0-or-later
// Games on an external drive (Settings › Downloads › External drive;
// experimental). The player picks a folder on a drive in Files; Playport keeps
// a bookmark to it and opens it at every start, before the runtime, so the
// whole process (the installer, Wine, the emulator) can use it while it runs.
// With "Install on the external drive" on, a new Steam install is staged and
// placed in <folder>/Playport Games/<installdir>, and C:\Games\<installdir> is
// a symbolic link to it: the library, the launch and Wine find the game where
// they always do. An update or a repair of such a game works on the drive. With
// the drive away, its games are not in the library until it is back.

import Combine
import Foundation
import PlayportKit
import SteamClientKit

@MainActor
final class ExternalStorage: ObservableObject {
    static let shared = ExternalStorage()

    static let bookmarkKey = "storage.external.bookmark"
    static let installKey = "storage.external.install"
    /// Settings' Choose the drive's folder: the shell opens the Files picker (AppShell).
    static let requests = PassthroughSubject<Void, Never>()

    /// The picked folder, open for this process; nil when none is picked or the drive is away.
    @Published private(set) var root: URL?
    /// The picked folder's name, also while the drive is away.
    @Published private(set) var name: String?

    private static func log(_ line: String) { SteamUILog.logger.info("storage", line) }

    /// Once, at the start of the app (PlayportApp), and again when Settings asks.
    func activate() {
        root?.stopAccessingSecurityScopedResource()
        root = nil
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { name = nil; return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            Self.log("the external drive's folder cannot be found (the drive is away?)")
            return
        }
        name = url.lastPathComponent
        guard url.startAccessingSecurityScopedResource() else {
            Self.log("\(url.lastPathComponent): no access (the drive is away?)")
            return
        }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            Self.log("\(url.lastPathComponent): not there (the drive is away?)")
            return
        }
        root = url
        Self.log("external drive folder \(url.lastPathComponent) open")
    }

    /// What the Files picker returned for Choose the drive's folder.
    func picked(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData()
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            Self.log("external drive folder chosen: \(url.lastPathComponent)")
        } catch {
            Self.log("\(url.lastPathComponent): no bookmark: \(error)")
        }
        activate()
    }

    /// The drive's folder is let go; its games stay on it, and C:\Games links to them stop working.
    func forget() {
        root?.stopAccessingSecurityScopedResource()
        root = nil
        name = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.set(false, forKey: Self.installKey)
        Self.log("external drive folder forgotten")
    }

    static var installsThere: Bool { UserDefaults.standard.bool(forKey: installKey) }

    /// The layout of installs on the drive: its staging and games beside each other on it (the
    /// commit is one rename), the records where they always are.
    func layout(base: InstallLayout) -> InstallLayout? {
        guard let root else { return nil }
        let top = root.appendingPathComponent("Playport Games", isDirectory: true)
        return InstallLayout(stagingRoot: top.appendingPathComponent(".staging", isDirectory: true), gamesRoot: top,
                             stateRoot: base.stateRoot)
    }

    /// Where C:\Games\<installDir> points when it is a link to the drive; nil for a folder.
    nonisolated static func target(of dir: URL) -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path) else { return nil }
        return URL(fileURLWithPath: dest, isDirectory: true)
    }

    enum Choice {
        case phone
        case drive(InstallLayout)
    }

    /// Where a Steam job for `appID` works: on the drive for a game already there (its C:\Games
    /// entry is a link) or for a new install while Settings says so; on the phone otherwise.
    func place(appID: UInt32, base: InstallLayout) throws -> Choice {
        let receipt = TitleInstaller(layout: base, session: nil, log: .silent).loadReceipt(appID)
        if let r = receipt {
            let entry = base.gamesRoot.appendingPathComponent(r.installDir, isDirectory: true)
            guard Self.target(of: entry) != nil else { return .phone }
            guard let l = layout(base: base) else {
                throw SteamError.unsupported("\(r.name) is on the external drive: connect it and open Playport again")
            }
            return .drive(l)
        }
        guard Self.installsThere else { return .phone }
        guard let l = layout(base: base) else {
            throw SteamError.unsupported("the external drive is not connected: connect it and open Playport again, "
                                         + "or turn Install on the external drive off")
        }
        return .drive(l)
    }

    /// After a job on the drive: C:\Games\<installDir> links to the game there.
    func link(appID: UInt32, drive: InstallLayout, base: InstallLayout) throws {
        guard let r = TitleInstaller(layout: base, session: nil, log: .silent).loadReceipt(appID) else { return }
        let entry = base.gamesRoot.appendingPathComponent(r.installDir, isDirectory: true)
        let there = drive.gamesRoot.appendingPathComponent(r.installDir, isDirectory: true)
        if Self.target(of: entry)?.standardizedFileURL.path == there.standardizedFileURL.path { return }
        try FileManager.default.createDirectory(at: base.gamesRoot, withIntermediateDirectories: true)
        if Self.target(of: entry) != nil { try FileManager.default.removeItem(at: entry) }
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: there)
        Self.log("C:\\Games\\\(r.installDir) -> the external drive")
    }
}
