// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

final class SaveBackupLayoutTests: XCTestCase {
    func testTheGamesFolderIsItsNameAsFilesShowsOne() {
        XCTAssertEqual(SaveBackupLayout.folderName("Trails in the Sky 1st Chapter"), "Trails in the Sky 1st Chapter")
        XCTAssertEqual(SaveBackupLayout.folderName("Ni no Kuni II: Revenant Kingdom"), "Ni no Kuni II- Revenant Kingdom")
        XCTAssertEqual(SaveBackupLayout.folderName("A/B\\C"), "A-B-C")
        XCTAssertEqual(SaveBackupLayout.folderName("..hidden"), "hidden")
        XCTAssertEqual(SaveBackupLayout.folderName("  "), "Game")
    }

    func testCloudNamesGoUnderTheirRoot() {
        XCTAssertEqual(SaveBackupLayout.path(forCloudName: "%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat"),
                       "WinAppDataLocalLow/Team Cherry/Hollow Knight/user1.dat")
        XCTAssertEqual(SaveBackupLayout.path(forCloudName: "save/slot1.sav"), "Steam Cloud/save/slot1.sav")
        XCTAssertEqual(SaveBackupLayout.path(forCloudName: "%GameInstall%saves\\a.sav"), "GameInstall/saves/a.sav")
        XCTAssertNil(SaveBackupLayout.path(forCloudName: "%WinMyDocuments%../../etc"))
        XCTAssertNil(SaveBackupLayout.path(forCloudName: "%WinMyDocuments%"))
    }

    func testAGameIsDueWhenPlayedSinceItsLastBackup() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(SaveBackupLayout.due(lastPlayed: nil, lastBackup: nil))
        XCTAssertTrue(SaveBackupLayout.due(lastPlayed: t, lastBackup: nil))
        XCTAssertTrue(SaveBackupLayout.due(lastPlayed: t, lastBackup: t.addingTimeInterval(-1)))
        XCTAssertFalse(SaveBackupLayout.due(lastPlayed: t, lastBackup: t))
    }
}
