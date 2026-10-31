// SPDX-License-Identifier: GPL-3.0-or-later
// Steam's downloads in the queue (Downloads.swift): install, update and
// repair through SteamClientKit's TitleInstaller. Steam's jobs run while Steam
// is signed in and the network is one Settings › Downloads allows (cellular,
// unless it says so). Updates Steam published are queued by themselves when
// Settings says so (`checkUpdates`). Uninstall and offline verify are
// LibraryModel's: they need no Steam session.

import Foundation
import PlayportKit
import SteamClientKit

@MainActor
final class SteamInstalls: DownloadDriver {
    private let service: SteamService
    private unowned let downloads: Downloads
    /// Steam is signed in: its jobs may run (the new process waits for its restore).
    private var signedIn = false

    init(service: SteamService, downloads: Downloads) {
        self.service = service
        self.downloads = downloads
    }

    var layout: InstallLayout { LibraryModel.paths.layout }

    var blocker: String? {
        if !signedIn { return "Waiting for Steam" }
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        guard let appID = job.appID else { throw ClientError.unsupported("\(job.key) is not a Steam game") }
        // On the external drive for a game there, or a new install chosen for it at Install (ExternalStorage).
        let place = try ExternalStorage.shared.place(appID: appID, base: layout)
        var drive: InstallLayout?
        if case let .drive(l) = place { drive = l }
        let installer = try await service.titleInstaller(layout: drive ?? layout)
        var engine = InstallEngine.Options()
        engine.progressInterval = 0.5
        // The progress lines go to the log from the queue, less often.
        let say: @Sendable (String) -> Void = { line in
            if !line.hasPrefix("progress:") { SteamUILog.logger.info("install", line) }
        }
        switch job.kind {
        case .install, .update:
            let r = try await installer.install(.init(appID: appID, branch: job.branch, engine: engine), progress: progress, say: say)
            if let drive { try ExternalStorage.shared.link(appID: appID, drive: drive, base: layout) }
            return job.kind == .install ? r.stage?.bytes : r.stage?.downloadedBytes
        case .repair:
            let r = try await installer.repair(appID: appID, engine: engine, progress: progress, say: say)
            LibraryModel.shared.recordVerification(appID: appID, report: r)
            return nil
        case .import:
            throw ClientError.unsupported("an import is not a Steam job")
        }
    }

    func finished(_ job: DownloadJob) {
        // What the game's Steam API emulator is told, while the session is up.
        if let app = job.appID { Task { await SteamAccountModel.current?.loadGameProfile(app, refresh: true) } }
    }

    func discard(_ key: StoreGameKey) {
        guard let appID = key.steamAppID else { return }
        ExternalStorage.shared.unchoose(appID)
        let installer = TitleInstaller(layout: layout, session: nil, log: SteamUILog.logger)
        // The journals first, at once, so the download no longer shows as resumable;
        // the staged trees can take a while. A job still winding down writes only
        // into files it has open, and the next run of it starts afresh.
        for n in (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        where n.hasPrefix("\(appID)_") && n.hasSuffix(".journal") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
        let drive = ExternalStorage.shared.layout(base: layout).map { TitleInstaller(layout: $0, session: nil, log: SteamUILog.logger) }
        Task.detached(priority: .utility) {
            installer.discardStage(appID: appID)
            drive?.discardStage(appID: appID)
        }
    }

    func reason(_ error: Error) -> String { InstallCopy.reason(error) }

    /// Steam's session is up (at every start of the app, once restored): its
    /// jobs run, with every hold but the player's let go.
    func signedIn(_ up: Bool) {
        guard up != signedIn else { return }
        signedIn = up
        // A session lost mid-download lets the running job go on; nothing new starts.
        downloads.conditionsChanged(letGoOf: up ? .steam : nil, stopBlocked: false)
    }

    /// Sign-out: every Steam job is held until Steam is signed in again.
    func holdForSignOut() {
        signedIn = false
        downloads.holdAll(of: .steam, .stopped(InstallCopy.signOut))
    }

    /// Queues the updates Steam published for installed games, when Settings
    /// › Downloads updates games by themselves (PlayportKit DownloadQueue.automaticUpdates).
    func checkUpdates(games: [SteamGame], titles: [InstalledTitle]) {
        guard !downloads.suspended, !TitleLaunch.shared.running else { return }
        let candidates = titles.compactMap { t -> UpdateCandidate? in
            // Only a Steam install follows Steam (SteamInstallStatus.updateAvailable).
            guard t.source == .installed, t.store == .steam, let app = t.appID,
                  let g = games.first(where: { $0.id == app }) else { return nil }
            // A game with files the player added (a translation) updates only from its page, which asks.
            guard !GameMods.shared.has(t.id) else { return nil }
            return UpdateCandidate(appID: app, name: t.name, installedBuild: t.buildID,
                                   steamBuild: g.info.depots.buildID(branch: t.branch ?? Branch.publicName))
        }
        downloads.queueAutomaticUpdates(candidates)
    }
}

/// Steam's shorthands on the queue, by app ID.
extension Downloads {
    /// Installs (or updates, or resumes) `appID`, on `branch` when one is
    /// named (a beta, or public to leave one); queued behind a running job.
    /// An installed game's download is its update.
    func install(_ appID: UInt32, name: String, branch: String? = nil) {
        let installed = LibraryModel.shared.catalog.titles.contains { $0.appID == appID }
        let bytes = SteamAccountModel.current?.games.first { $0.id == appID }?.info.installSize(branch: branch ?? Branch.publicName)
        let drive = ExternalStorage.shared
        // A new game, with the drive connected and nothing of it downloaded yet: where it goes.
        if !installed, drive.root != nil, jobs[.steam(appID)] == nil, !hasStage(appID) {
            let phoneFree = LibraryModel.shared.freeBytes
            let driveFree = drive.capacity()?.free
            func detail(_ free: UInt64?) -> String? {
                guard let free else { return nil }
                let short = bytes.map { $0 > free } ?? false
                return ByteCount.format(free) + " free" + (short ? " · not enough" : "")
            }
            PadModal.shared.picker(
                title: "Install \(name) on", context: bytes.map { "Needs " + ByteCount.format($0) },
                options: [PadOption(id: "phone", label: "iPhone", detail: detail(phoneFree)),
                          PadOption(id: "drive", label: drive.name ?? "External drive", detail: detail(driveFree))],
                selected: drive.chosenDrive(appID) ? "drive" : "phone") { [weak self] choice in
                drive.choose(appID: appID, drive: choice == "drive")
                self?.enqueue(DownloadJob(appID: appID, name: name, kind: .install, branch: branch, bytes: bytes))
            }
            return
        }
        enqueue(DownloadJob(appID: appID, name: name, kind: installed ? .update : .install, branch: branch,
                            bytes: installed ? nil : bytes))
    }

    /// Re-downloads the files of a Steam install that fail verification.
    func repair(_ appID: UInt32, name: String) { enqueue(DownloadJob(appID: appID, name: name, kind: .repair)) }

    func resume(_ appID: UInt32) { resume(.steam(appID)) }
    func pause(_ appID: UInt32) { pause(.steam(appID)) }
    func downloadNext(_ appID: UInt32) { downloadNext(.steam(appID)) }
    func discard(_ appID: UInt32) { discard(.steam(appID)) }

    /// A download of `appID` left on disk by an earlier run, with no job for it now.
    func hasStageOnDisk(_ appID: UInt32) -> Bool { jobs[.steam(appID)] == nil && hasStage(appID) }

    /// A download of `appID` left on the phone or on the drive.
    private func hasStage(_ appID: UInt32) -> Bool {
        if TitleInstaller(layout: layout, session: nil, log: .silent).hasStage(appID: appID) { return true }
        guard let l = ExternalStorage.shared.layout(base: layout) else { return false }
        return TitleInstaller(layout: l, session: nil, log: .silent).hasStage(appID: appID)
    }
}
