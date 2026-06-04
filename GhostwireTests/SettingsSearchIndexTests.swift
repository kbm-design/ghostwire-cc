//
//  SettingsSearchIndexTests.swift
//  GhostwireTests
//
//  GW-144: settings search query → pane matching.
//

import XCTest
@testable import Ghostwire

final class SettingsSearchIndexTests: XCTestCase {

    func testEmptyQueryMatchesEverything() {
        let all = Set((SettingsSearchIndex.core + SettingsSearchIndex.modules).map(\.id))
        XCTAssertEqual(SettingsSearchIndex.matches(""), all)
        XCTAssertEqual(SettingsSearchIndex.matches("   "), all)
    }

    func testLabelMatchIsCaseInsensitive() {
        XCTAssertTrue(SettingsSearchIndex.matches("AGENTS").contains("Agents"))
        XCTAssertTrue(SettingsSearchIndex.matches("battery").contains("Battery"))
    }

    func testKeywordMatch() {
        XCTAssertTrue(SettingsSearchIndex.matches("volume").contains("HUD"))
        XCTAssertTrue(SettingsSearchIndex.matches("codex").contains("Agents"))
        XCTAssertTrue(SettingsSearchIndex.matches("webcam").contains("Mirror"))
        XCTAssertTrue(SettingsSearchIndex.matches("lyrics").contains("Media"))
    }

    func testPartialKeywordMatch() {
        // Substring matching: "bright" should find brightness (HUD)
        XCTAssertTrue(SettingsSearchIndex.matches("bright").contains("HUD"))
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(SettingsSearchIndex.matches("zzzznothing").isEmpty)
    }

    func testEveryPaneIdHasAUniqueEntry() {
        let ids = (SettingsSearchIndex.core + SettingsSearchIndex.modules).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testModuleEntriesMirrorSettingsModules() {
        // The MODULES sidebar renders from SettingsModule.all but search
        // filters by SettingsSearchIndex — they must stay in sync.
        XCTAssertEqual(
            SettingsSearchIndex.modules.map(\.id),
            SettingsModule.all.map(\.id)
        )
    }

    func testEveryModuleHasKeywords() {
        // Entries derive from SettingsModule.all + a keyword map keyed by
        // id — a new module with no map entry would be label-searchable only.
        for entry in SettingsSearchIndex.modules {
            XCTAssertFalse(entry.keywords.isEmpty, "\(entry.id) has no search keywords")
        }
    }
}
