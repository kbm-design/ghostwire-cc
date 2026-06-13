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

    func testSetHiddenRefusesToHideAgentsTab() {
        // The Agents tab is the approval surface (GW-139): hiding it would
        // strand pending permissions, so setHidden must be a no-op.
        let savedHidden = Defaults[.hiddenNotchTabs]
        defer { Defaults[.hiddenNotchTabs] = savedHidden }
        Defaults[.hiddenNotchTabs] = []

        NotchTab.setHidden(.agents, true)

        XCTAssertFalse(Defaults[.hiddenNotchTabs].contains(NotchTab.agents.rawValue))
    }

    func testEnsureAgentsVisibleForApprovalClearsLegacyState() {
        // Prefs persisted before the no-hiding rule can still carry the
        // entry — the bridge calls this on every new pending permission
        // (GhostwireSessionBridge.handlePendingPermissionSessions), so a
        // stranded approval restores its tab.
        let savedHidden = Defaults[.hiddenNotchTabs]
        let savedShelf = Defaults[.shelf]
        defer {
            Defaults[.hiddenNotchTabs] = savedHidden
            Defaults[.shelf] = savedShelf
        }
        Defaults[.shelf] = true
        Defaults[.hiddenNotchTabs] = [NotchTab.agents.rawValue, NotchTab.dashboard.rawValue]
        XCTAssertFalse(NotchTab.currentlyVisible.contains(.agents))

        NotchTab.ensureAgentsVisibleForApproval()

        XCTAssertEqual(Defaults[.hiddenNotchTabs], [NotchTab.dashboard.rawValue])
        XCTAssertTrue(NotchTab.currentlyVisible.contains(.agents))
    }

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

/// GW-226: the default-open tab policy. Last-selected tab is the baseline; a
/// pending approval forces Agents; an explicit save arms a one-shot Shelf reveal.
@MainActor
final class NotchDefaultViewPolicyTests: XCTestCase {

    private func withAllTabsVisible(_ body: () throws -> Void) rethrows {
        let savedHidden = Defaults[.hiddenNotchTabs]
        let savedShelf = Defaults[.shelf]
        let savedOrder = Defaults[.notchTabOrder]
        let coordinator = GhostwireViewCoordinator.shared
        let savedProvider = coordinator.pendingApprovalProvider
        let savedLast = coordinator.lastSelectedTab
        let savedReveal = coordinator.pendingShelfReveal
        defer {
            Defaults[.hiddenNotchTabs] = savedHidden
            Defaults[.shelf] = savedShelf
            Defaults[.notchTabOrder] = savedOrder
            coordinator.pendingApprovalProvider = savedProvider
            coordinator.lastSelectedTab = savedLast
            coordinator.pendingShelfReveal = savedReveal
        }
        Defaults[.hiddenNotchTabs] = []
        Defaults[.shelf] = true
        Defaults[.notchTabOrder] = NotchTab.allCases.map(\.rawValue)
        coordinator.pendingApprovalProvider = { false }   // deterministic: no live approval
        try body()
    }

    func testFallsBackToLastSelectedTab() {
        withAllTabsVisible {
            let coordinator = GhostwireViewCoordinator.shared
            coordinator.pendingShelfReveal = false
            coordinator.lastSelectedTab = .home
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .home)
        }
    }

    func testPendingApprovalForcesAgentsOverLastTab() {
        withAllTabsVisible {
            let coordinator = GhostwireViewCoordinator.shared
            coordinator.lastSelectedTab = .shelf
            coordinator.pendingApprovalProvider = { true }
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .buddy, "a pending approval must win over the last tab")
        }
    }

    func testOneShotShelfRevealThenRevertsToLastTab() {
        withAllTabsVisible {
            let coordinator = GhostwireViewCoordinator.shared
            coordinator.lastSelectedTab = .home
            coordinator.pendingShelfReveal = true

            // Armed → next open reveals the Shelf.
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .shelf)

            // applyDefaultViewOnOpen consumes the one-shot…
            coordinator.applyDefaultViewOnOpen()
            XCTAssertFalse(coordinator.pendingShelfReveal)

            // …and a subsequent open reverts to the last selected tab.
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .home)
        }
    }
}
