// SPDX-License-Identifier: GPL-3.0-or-later
// What the Library, the game page (GameDetailView) and Downloads share: a
// game's update check and how a version is named.

import PlayportKit
import SteamClientKit
import SwiftUI

/// The games list's line under a game: its download, or that it is installed.
struct SteamInstallStatus: View {
    let game: SteamGame
    @ObservedObject var installs: Downloads
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        if let job = installs.jobs[.steam(game.id)] {
            Text(job.status).font(.caption.bold()).foregroundStyle(.tint)
        } else if let t = library.catalog.titles.first(where: { $0.appID == game.id }) {
            let update = Self.updateAvailable(t, game.info)
            Text(update ? "Update available" : "Installed")
                .font(.caption.bold())
                .foregroundStyle(update ? Color.orange : Color.green)
        }
    }

    /// Only a Steam install follows Steam, on the branch it was installed
    /// from: a pinned cohort title stays on its tested build, and a copied-in
    /// one has no record to update.
    static func updateAvailable(_ t: InstalledTitle, _ info: SteamAppInfo) -> Bool {
        guard t.source == .installed, let now = info.depots.buildID(branch: t.branch ?? Branch.publicName) else { return false }
        return t.buildID != now
    }

    /// Owned DLC (the emulator's profile) whose depots the install lacks: an install made
    /// while Playport left every DLC depot out (The Witcher 3's expansions). Downloading them
    /// is an update of the same build that keeps the files the install has.
    static func missingDLC(_ t: InstalledTitle, _ info: SteamAppInfo, _ profile: SteamGameProfile?) -> [UInt32] {
        guard t.source == .installed, t.store == .steam, let profile, !profile.dlc.isEmpty,
              let depots = try? info.depots.onBranch(t.branch ?? Branch.publicName) else { return [] }
        return DepotSelection.missingDLC(depots, installed: Set(t.depots.map(\.depotID)), ownedDLC: Set(profile.dlc.map(\.appID)))
    }
}

/// A branch as the version picker names it: public is the default, a beta
/// its name and Steam's description (`classic · 1.32 (DX11)`).
enum BranchLabel {
    static func text(_ b: Branch) -> String {
        if b.isPublic { return "Latest (default)" }
        return [b.name, b.description].compactMap { $0 }.joined(separator: " · ")
    }

    static func text(_ name: String?, in info: SteamAppInfo?) -> String {
        let name = name ?? Branch.publicName
        return info?.depots.branch(name).map(text) ?? (name == Branch.publicName ? "Latest (default)" : name)
    }
}
