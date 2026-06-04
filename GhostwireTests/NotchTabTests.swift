//
//  NotchTabTests.swift
//  GhostwireTests
//
//  GW-144: notch tab order/visibility sanitization. Pure helpers only —
//  the Defaults-backed accessors are thin wrappers over these.
//

import Defaults
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
        // Everything hidden → ignore the hide list rather than render an
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

    func testEmptyFallbackNeverResurrectsDisabledShelf() {
        // F1 regression (code review): agents+dashboard hidden, then the
        // Shelf MODULE turned off — the fallback must ignore the hide list
        // but never resurrect the module-disabled Shelf tab.
        XCTAssertEqual(
            NotchTab.visibleTabs(
                order: NotchTab.allCases,
                hidden: ["agents", "dashboard"],
                shelfEnabled: false
            ),
            [.agents, .dashboard]
        )
    }

    func testShelfHiddenAndDisabledStaysGone() {
        // Hide list and module gate agree — shelf stays out, others remain.
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: ["shelf"], shelfEnabled: false),
            [.agents, .dashboard]
        )
    }
}

/// End-to-end repair path (review M1 / second-pass warning): the Shelf
/// MODULE toggle writes Defaults[.shelf] directly, bypassing setHidden —
/// the coordinator's Defaults observer must still move currentView off
/// the vanished tab.
@MainActor
final class NotchTabRepairTests: XCTestCase {

    func testShelfModuleToggleRepairsCurrentView() async throws {
        let savedShelf = Defaults[.shelf]
        let savedHidden = Defaults[.hiddenNotchTabs]
        let savedOrder = Defaults[.notchTabOrder]
        let coordinator = GhostwireViewCoordinator.shared
        let savedView = coordinator.currentView
        defer {
            Defaults[.shelf] = savedShelf
            Defaults[.hiddenNotchTabs] = savedHidden
            Defaults[.notchTabOrder] = savedOrder
            coordinator.currentView = savedView
        }

        Defaults[.hiddenNotchTabs] = []
        Defaults[.notchTabOrder] = NotchTab.allCases.map(\.rawValue)
        Defaults[.shelf] = true
        coordinator.currentView = .shelf

        // The module-toggle path: a bare Defaults write, no setHidden.
        Defaults[.shelf] = false

        // Repair hops once through the main actor — poll briefly.
        let deadline = Date().addingTimeInterval(2)
        while coordinator.currentView == .shelf && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotEqual(
            coordinator.currentView, .shelf,
            "coordinator's Defaults observer should repair currentView when the Shelf module is disabled"
        )
    }
}
