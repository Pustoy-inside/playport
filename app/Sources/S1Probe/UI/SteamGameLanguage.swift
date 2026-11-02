// SPDX-License-Identifier: GPL-3.0-or-later
// A Steam game's language, as Steam's Properties › Language picks it (PlayportKit
// GameLanguage): the game's own choice on its page (Game options › Language), else
// Settings › Downloads › Game language. Installs download that language's depots
// (SteamInstalls.run); a launch tells the Steam API emulator the language whose
// files the install has (LibraryModel.play).

import Foundation
import PlayportKit
import SteamClientKit

@MainActor
enum SteamGameLanguage {
    static func titleID(_ appID: UInt32) -> String { "app-\(appID)" }

    static func info(_ appID: UInt32) -> SteamAppInfo? {
        SteamAccountModel.current?.games.first { $0.id == appID }?.info
    }

    /// The game's own choice, nil when it follows the default.
    static func own(_ appID: UInt32) -> String? { LaunchSettingsStore.shared.settings(for: titleID(appID)).language }

    /// The language the game downloads and runs in.
    static func chosen(_ appID: UInt32, info: SteamAppInfo? = nil) -> String {
        GameLanguage.resolve(game: own(appID), global: LaunchSettingsStore.shared.global.language,
                             offered: (info ?? Self.info(appID))?.offeredLanguages ?? [])
    }

    /// What the emulator is told at a launch of `t`: the chosen language, once its files are installed.
    static func running(_ t: InstalledTitle) -> String? {
        guard let app = t.appID, t.store == .steam else { return nil }
        let info = info(app)
        return GameLanguage.running(chosen(app, info: info), languageDepots: info?.languageDepots ?? [:],
                                    installed: Set(t.depots.map(\.depotID)))
    }

    /// The install's language files differ from the chosen language's: an update downloads them.
    static func needsUpdate(_ t: InstalledTitle, _ info: SteamAppInfo) -> Bool {
        guard t.source == .installed, t.store == .steam, let app = t.appID else { return false }
        return GameLanguage.needsUpdate(chosen(app, info: info), languageDepots: info.languageDepots,
                                        installed: Set(t.depots.map(\.depotID)))
    }
}
