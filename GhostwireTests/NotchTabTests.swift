//
//  NotchTabTests.swift
//  GhostwireTests
//
//  GW-144: notch tab order/visibility sanitization. Pure helpers only —
//  the Defaults-backed accessors are thin wrappers over these.
//

import XCTest
@testable import Ghostwire

final class NotchTabTests: XCTestCase {

    // MARK: - sanitizedOrder

    func testSanitizedOrderPreservesValidOrder() {
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["shelf", "agents", "dashboard"]),
            [.shelf, .agents, .dashboard]
        )
    }

    func testSanitizedOrderDropsUnknownIds() {
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["agents", "downloads", "dashboard", "shelf"]),
            [.agents, .dashboard, .shelf]
        )
    }

    func testSanitizedOrderDeduplicates() {
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["agents", "agents", "shelf", "dashboard", "shelf"]),
            [.agents, .shelf, .dashboard]
        )
    }

    func testSanitizedOrderAppendsMissingTabs() {
        // Forward-compat: a stored order from before a new tab shipped
        // gets the new tab appended in declaration order.
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["shelf"]),
            [.shelf, .agents, .dashboard]
        )
    }

    func testSanitizedOrderEmptyFallsBackToDeclarationOrder() {
        XCTAssertEqual(NotchTab.sanitizedOrder([]), NotchTab.allCases)
    }

    // MARK: - visibleTabs

    func testVisibleTabsFiltersHidden() {
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: ["dashboard"], shelfEnabled: true),
            [.agents, .shelf]
        )
    }

    func testVisibleTabsRespectsShelfModuleToggle() {
        // Shelf has no separate visibility key — module off removes the tab.
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: [], shelfEnabled: false),
            [.agents, .dashboard]
        )
    }

    func testVisibleTabsPreservesUserOrder() {
        XCTAssertEqual(
            NotchTab.visibleTabs(order: [.shelf, .dashboard, .agents], hidden: [], shelfEnabled: true),
            [.shelf, .dashboard, .agents]
        )
    }

    func testVisibleTabsNeverEmpty() {
        // Everything hidden → fall back to full order rather than an
        // empty (and unrecoverable) notch.
        XCTAssertEqual(
            NotchTab.visibleTabs(
                order: NotchTab.allCases,
                hidden: Set(NotchTab.allCases.map(\.rawValue)),
                shelfEnabled: true
            ),
            NotchTab.allCases
        )
    }
}
