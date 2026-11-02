// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The language a Steam game downloads and runs in, as Steam's game Properties ›
/// Language sets it: Steam's API language codes (`english`, `russian`, …), which pick
/// the game's language depots (DepotSelection.Options.language) and what the Steam API
/// emulator answers GetCurrentGameLanguage with (SteamAPISwap.Settings.language).
/// Settings › Downloads sets the default (LaunchSettings.language, global); a game's
/// page sets its own.
public enum GameLanguage {
    public static let fallback = "english"

    /// Steam's languages, by API code, with each one's own name.
    public static let all: [(code: String, name: String)] = [
        ("english", "English"), ("russian", "Русский"), ("ukrainian", "Українська"), ("german", "Deutsch"),
        ("french", "Français"), ("italian", "Italiano"), ("spanish", "Español (España)"),
        ("latam", "Español (Latinoamérica)"), ("portuguese", "Português (Portugal)"),
        ("brazilian", "Português (Brasil)"), ("polish", "Polski"), ("czech", "Čeština"), ("hungarian", "Magyar"),
        ("romanian", "Română"), ("bulgarian", "Български"), ("greek", "Ελληνικά"), ("turkish", "Türkçe"),
        ("dutch", "Nederlands"), ("swedish", "Svenska"), ("danish", "Dansk"), ("norwegian", "Norsk"),
        ("finnish", "Suomi"), ("japanese", "日本語"), ("koreana", "한국어"), ("schinese", "简体中文"),
        ("tchinese", "繁體中文"), ("thai", "ไทย"), ("vietnamese", "Tiếng Việt"), ("indonesian", "Bahasa Indonesia"),
        ("arabic", "العربية"),
    ]

    /// A language's own name; an unknown code as Steam spells it.
    public static func name(_ code: String) -> String {
        all.first { $0.code == code.lowercased() }?.name ?? code.capitalized
    }

    /// The languages a game offers, in `all`'s order (unknown codes after), English first:
    /// `offered` as Steam lists them (SteamAppInfo.languages); empty when unknown.
    public static func choices(offered: [String]) -> [String] {
        let set = Set(offered.map { $0.lowercased() })
        let known = all.map(\.code).filter(set.contains)
        return known + set.subtracting(known).sorted()
    }

    /// The language a game runs in: its own choice, else the default when the game offers
    /// it (or its languages are unknown), else English when it offers that, else its first.
    public static func resolve(game: String?, global: String?, offered: [String]) -> String {
        if let game = game?.lowercased(), !game.isEmpty { return game }
        let choices = choices(offered: offered)
        if let global = global?.lowercased(), !global.isEmpty, choices.isEmpty || choices.contains(global) { return global }
        if choices.isEmpty || choices.contains(fallback) { return fallback }
        return choices[0]
    }

    /// What the game is told at a launch: `language`, unless the game has a depot for it
    /// that its install lacks (chosen, not downloaded yet), when it is English, which it
    /// was installed with: a game told a language whose files are missing may not start.
    /// `languageDepots` maps the game's language depots to their languages.
    public static func running(_ language: String, languageDepots: [UInt32: String], installed: Set<UInt32>) -> String {
        let needed = languageDepots.filter { $0.value == language }.map(\.key)
        if needed.isEmpty || needed.contains(where: installed.contains) { return language }
        let installedLanguage = languageDepots.first { installed.contains($0.key) }?.value
        return installedLanguage ?? fallback
    }

    /// Whether the install's language depots differ from `language`'s: it lacks one of
    /// them (a download brings it) or has another language's (an update takes it out).
    public static func needsUpdate(_ language: String, languageDepots: [UInt32: String], installed: Set<UInt32>) -> Bool {
        let mine = Set(languageDepots.filter { $0.value == language }.map(\.key))
        let others = Set(languageDepots.keys).subtracting(mine)
        return !mine.isEmpty && !mine.contains(where: installed.contains) || others.contains(where: installed.contains)
    }
}
