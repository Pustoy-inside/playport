// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

final class GameLanguageTests: XCTestCase {
    func testTheGamesOwnChoiceThenTheDefaultWhereOffered() {
        let offered = ["english", "russian", "german"]
        XCTAssertEqual(GameLanguage.resolve(game: nil, global: nil, offered: offered), "english")
        XCTAssertEqual(GameLanguage.resolve(game: nil, global: "russian", offered: offered), "russian")
        XCTAssertEqual(GameLanguage.resolve(game: "german", global: "russian", offered: offered), "german")
        // A game without Russian runs in English.
        XCTAssertEqual(GameLanguage.resolve(game: nil, global: "russian", offered: ["english", "french"]), "english")
        // Languages unknown: the default as chosen.
        XCTAssertEqual(GameLanguage.resolve(game: nil, global: "russian", offered: []), "russian")
        // No English: the game's first.
        XCTAssertEqual(GameLanguage.resolve(game: nil, global: "russian", offered: ["japanese", "schinese"]), "japanese")
    }

    func testChoicesInSteamsOrder() {
        XCTAssertEqual(GameLanguage.choices(offered: ["German", "russian", "english", "klingon"]),
                       ["english", "russian", "german", "klingon"])
        XCTAssertEqual(GameLanguage.name("russian"), "Русский")
        XCTAssertEqual(GameLanguage.name("klingon"), "Klingon")
    }

    func testTheGameIsToldALanguageOnlyOnceItsFilesAreInstalled() {
        let depots: [UInt32: String] = [11: "russian", 12: "german"]
        // A game whose languages share one depot: told at once.
        XCTAssertEqual(GameLanguage.running("russian", languageDepots: [:], installed: [10]), "russian")
        XCTAssertFalse(GameLanguage.needsUpdate("russian", languageDepots: [:], installed: [10]))
        // Russian chosen, its depot not downloaded yet: still English, and an update is due.
        XCTAssertEqual(GameLanguage.running("russian", languageDepots: depots, installed: [10]), "english")
        XCTAssertTrue(GameLanguage.needsUpdate("russian", languageDepots: depots, installed: [10]))
        XCTAssertEqual(GameLanguage.running("russian", languageDepots: depots, installed: [10, 11]), "russian")
        XCTAssertFalse(GameLanguage.needsUpdate("russian", languageDepots: depots, installed: [10, 11]))
        // Back to English with German's files in: told the installed one until the update takes them out.
        XCTAssertEqual(GameLanguage.running("english", languageDepots: depots, installed: [10, 12]), "english")
        XCTAssertTrue(GameLanguage.needsUpdate("english", languageDepots: depots, installed: [10, 12]))
        XCTAssertEqual(GameLanguage.running("russian", languageDepots: depots, installed: [10, 12]), "german")
    }

    func testTheSettingIsKeptAndInheritedOverACompatibilityDefault() throws {
        let s = LaunchSettings(language: "russian")
        XCTAssertFalse(s.isEmpty)
        let back = try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.language, "russian")
        XCTAssertNil(try JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8)).language)
        let own = LaunchSettings(language: "russian")
        let merged = own.over(LaunchSettings(frameLimit: 30, jitPoolMB: 768))
        XCTAssertEqual(merged.language, "russian")
        XCTAssertEqual(merged.jitPoolMB, 768)
        XCTAssertEqual(merged.frameLimit, 30)
    }
}
