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
            [.shelf, .agents, .dashboard, .feed]
        )
    }

    func testSanitizedOrderDropsUnknownIds() {
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["agents", "downloads", "dashboard", "shelf"]),
            [.agents, .dashboard, .shelf, .feed]
        )
    }

    func testSanitizedOrderDeduplicates() {
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["agents", "agents", "shelf", "dashboard", "shelf"]),
            [.agents, .shelf, .dashboard, .feed]
        )
    }

    func testSanitizedOrderAppendsMissingTabs() {
        // Forward-compat: a stored order from before a new tab shipped
        // gets the new tab appended in declaration order.
        XCTAssertEqual(
            NotchTab.sanitizedOrder(["shelf"]),
            [.shelf, .agents, .dashboard, .feed]
        )
    }

    func testSanitizedOrderEmptyFallsBackToDeclarationOrder() {
        XCTAssertEqual(NotchTab.sanitizedOrder([]), NotchTab.allCases)
    }

    // MARK: - visibleTabs

    func testVisibleTabsFiltersHidden() {
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: ["dashboard"], shelfEnabled: true),
            [.agents, .shelf, .feed]
        )
    }

    func testVisibleTabsRespectsShelfModuleToggle() {
        // Shelf has no separate visibility key — module off removes the tab.
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: [], shelfEnabled: false),
            [.agents, .dashboard, .feed]
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
                hidden: ["agents", "dashboard", "feed"],
                shelfEnabled: false
            ),
            [.agents, .dashboard, .feed]
        )
    }

    func testShelfHiddenAndDisabledStaysGone() {
        // Hide list and module gate agree — shelf stays out, others remain.
        XCTAssertEqual(
            NotchTab.visibleTabs(order: NotchTab.allCases, hidden: ["shelf"], shelfEnabled: false),
            [.agents, .dashboard, .feed]
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

    /// GW-472: a private coordinator, never `.shared`. The test host is the
    /// live app, whose notch UI writes `.shared.currentView` while this test
    /// polls it — the residual 1-in-9 flake after GW-444.
    func testShelfModuleToggleRepairsCurrentView() async throws {
        let savedShelf = Defaults[.shelf]
        let savedHidden = Defaults[.hiddenNotchTabs]
        let savedOrder = Defaults[.notchTabOrder]
        let coordinator = await GhostwireViewCoordinator()
        defer {
            Defaults[.shelf] = savedShelf
            Defaults[.hiddenNotchTabs] = savedHidden
            Defaults[.notchTabOrder] = savedOrder
        }

        Defaults[.hiddenNotchTabs] = []
        Defaults[.notchTabOrder] = NotchTab.allCases.map(\.rawValue)
        Defaults[.shelf] = true
        await MainActor.run { coordinator.currentView = .shelf }

        // The module-toggle path: a bare Defaults write, no setHidden.
        Defaults[.shelf] = false

        // Repair hops once through the main actor — poll briefly.
        let deadline = Date().addingTimeInterval(2)
        while await coordinator.currentView == .shelf, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let repaired = await coordinator.currentView
        XCTAssertNotEqual(
            repaired, .shelf,
            "coordinator's Defaults observer should repair currentView when the Shelf module is disabled"
        )
    }
}

/// GW-226: the default-open tab policy. Last-selected tab is the baseline; a
/// pending approval forces Agents; an explicit save arms a one-shot Shelf reveal.
@MainActor
final class NotchDefaultViewPolicyTests: XCTestCase {

    /// Runs `body` against a PRIVATE coordinator with every tab visible. Not
    /// `.shared`: the test host is the live app, and its notch UI mutates the
    /// shared coordinator's `currentView` / `lastSelectedTab` under a test (GW-472).
    private func withAllTabsVisible(_ body: (GhostwireViewCoordinator) throws -> Void) rethrows {
        let savedHidden = Defaults[.hiddenNotchTabs]
        let savedShelf = Defaults[.shelf]
        let savedOrder = Defaults[.notchTabOrder]
        defer {
            Defaults[.hiddenNotchTabs] = savedHidden
            Defaults[.shelf] = savedShelf
            Defaults[.notchTabOrder] = savedOrder
        }
        Defaults[.hiddenNotchTabs] = []
        Defaults[.shelf] = true
        Defaults[.notchTabOrder] = NotchTab.allCases.map(\.rawValue)
        try body(GhostwireViewCoordinator())
    }

    func testFallsBackToLastSelectedTab() {
        withAllTabsVisible { coordinator in
            coordinator.pendingShelfReveal = false
            coordinator.lastSelectedTab = .home
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .home)
        }
    }

    func testFreshAlertAutoRevealRoutesToAgents() {
        // GW-224: the alert ITSELF (auto-reveal) routes to Agents so Allow/Deny
        // is in front the moment it arrives.
        withAllTabsVisible { coordinator in
            coordinator.lastSelectedTab = .shelf
            coordinator.currentView = .shelf
            coordinator.showAgentsForApproval()
            XCTAssertEqual(coordinator.currentView, .buddy, "a fresh alert must land on Agents")
        }
    }

    func testApprovalDoesNotForceAgentsOnManualReopen() {
        // GW-224 (the reported flaw): once you've navigated away from an approval
        // you're choosing not to answer, a manual reopen must respect your
        // last-used tab — not keep dragging you back to Agents. The pending row
        // still waits in the Agents tab regardless.
        withAllTabsVisible { coordinator in
            coordinator.pendingShelfReveal = false
            coordinator.lastSelectedTab = .shelf
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .shelf)
        }
    }

    func testOneShotShelfRevealThenRevertsToLastTab() {
        withAllTabsVisible { coordinator in
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

    // MARK: - GW-224: no-alert opens must NOT default to Agents

    func testNoAlertDefaultLandsOnShelfNotAgents() {
        // GW-224: with the last-used memory at its default and no pending
        // approval, a manual/hover open lands on Shelf (the utility home),
        // never on Agents. (Restores GW-203's shelf-by-default intent that
        // GW-226 overcorrected into always-Agents.)
        withAllTabsVisible { coordinator in
            coordinator.pendingShelfReveal = false
            coordinator.lastSelectedTab = GhostwireViewCoordinator.defaultLastSelectedTab
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .shelf)
        }
    }

    func testDefaultLastSelectedTabIsShelf() {
        // The "reopen here" baseline is Shelf, not Agents.
        XCTAssertEqual(GhostwireViewCoordinator.defaultLastSelectedTab, .shelf)
    }

    func testFallbackPrefersShelfWhenLastTabHidden() {
        // GW-224: no approval, and the last-selected tab is no longer visible
        // → fall back to Shelf rather than defaulting to Agents.
        withAllTabsVisible { coordinator in
            coordinator.pendingShelfReveal = false
            Defaults[.hiddenNotchTabs] = [NotchTab.dashboard.rawValue]  // Home hidden
            coordinator.lastSelectedTab = .home                         // points at the hidden tab
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .shelf)
        }
    }

    func testRestoresShelfAsLastUsedSurface() {
        // The voice/clipboard/drop reveal paths record Shelf as the last-used
        // surface; a later no-alert open must return there.
        withAllTabsVisible { coordinator in
            coordinator.pendingShelfReveal = false
            coordinator.lastSelectedTab = .shelf
            XCTAssertEqual(coordinator.defaultViewOnOpen(), .shelf)
        }
    }
}
