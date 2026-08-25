//
//  NotchTab.swift
//  Ghostwire
//
//  Notch tab identity + user-managed visibility/order (GW-144, Perch's
//  Tab Management pattern). TabSelectionView renders `currentlyVisible`;
//  the General settings pane edits order and visibility.
//

import Defaults
import Foundation

enum NotchTab: String, CaseIterable, Identifiable {
    case agents
    case dashboard
    case shelf
    case feed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agents: return "Agents"
        case .dashboard: return "Dashboard"
        case .shelf: return "Shelf"
        case .feed: return "Feed"
        }
    }

    var icon: String {
        switch self {
        case .agents: return "terminal.fill"
        case .dashboard: return "square.grid.2x2"
        case .shelf: return "tray.fill"
        // GW-259: git-fork/branch glyph — the feed surfaces things pulled from
        // sources (MCPs etc.), distinct from the media Dashboard.
        case .feed: return "arrow.triangle.branch"
        }
    }

    var view: NotchViews {
        switch self {
        case .agents: return .buddy
        case .dashboard: return .home
        case .shelf: return .shelf
        case .feed: return .feed
        }
    }

    // MARK: - Order + visibility (pure helpers, unit-tested)

    /// Persisted order, sanitized: unknown ids dropped, duplicates removed,
    /// tabs missing from the stored value appended in declaration order
    /// (forward-compat when a new tab ships).
    static func sanitizedOrder(_ raw: [String]) -> [NotchTab] {
        var seen = Set<NotchTab>()
        var order: [NotchTab] = []
        for id in raw {
            guard let tab = NotchTab(rawValue: id), !seen.contains(tab) else { continue }
            seen.insert(tab)
            order.append(tab)
        }
        for tab in allCases where !seen.contains(tab) {
            order.append(tab)
        }
        return order
    }

    /// Visible tabs in user order. The Shelf tab additionally follows its
    /// module toggle (`Defaults[.shelf]`) — one source of truth, no second key.
    /// Never returns empty: if every module-enabled tab is hidden, the hide
    /// list is ignored — but a module-disabled tab is never resurrected.
    static func visibleTabs(order: [NotchTab], hidden: Set<String>, shelfEnabled: Bool) -> [NotchTab] {
        let enabled = order.filter { $0 != .shelf || shelfEnabled }
        let visible = enabled.filter { !hidden.contains($0.rawValue) }
        return visible.isEmpty ? enabled : visible
    }

    // MARK: - Defaults-backed accessors

    static var currentOrder: [NotchTab] {
        sanitizedOrder(Defaults[.notchTabOrder])
    }

    static var currentlyVisible: [NotchTab] {
        visibleTabs(
            order: currentOrder,
            hidden: Defaults[.hiddenNotchTabs],
            shelfEnabled: Defaults[.shelf]
        )
    }

    /// Move this tab one slot up/down in the persisted order.
    static func move(_ tab: NotchTab, up: Bool) {
        var order = currentOrder
        guard let index = order.firstIndex(of: tab) else { return }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        Defaults[.notchTabOrder] = order.map(\.rawValue)
    }

    /// Hide/show a tab. Refuses to hide the Agents tab (it's the approval
    /// surface — hiding it would strand pending permissions, GW-139) and
    /// the last visible tab.
    @MainActor
    static func setHidden(_ tab: NotchTab, _ hidden: Bool) {
        var hiddenIds = Defaults[.hiddenNotchTabs]
        if hidden {
            guard tab != .agents else { return }
            let remaining = currentlyVisible.filter { $0 != tab }
            guard !remaining.isEmpty else { return }
            hiddenIds.insert(tab.rawValue)
            Defaults[.hiddenNotchTabs] = hiddenIds
            ensureCurrentViewVisible()
        } else {
            hiddenIds.remove(tab.rawValue)
            Defaults[.hiddenNotchTabs] = hiddenIds
        }
    }

    /// The Agents tab must be reachable whenever an approval is pending.
    /// setHidden refuses to hide it, but persisted prefs from before that
    /// rule (or direct Defaults writes) can still carry the entry — the
    /// bridge calls this on every new pending permission.
    @MainActor
    static func ensureAgentsVisibleForApproval() {
        var hiddenIds = Defaults[.hiddenNotchTabs]
        guard hiddenIds.contains(NotchTab.agents.rawValue) else { return }
        hiddenIds.remove(NotchTab.agents.rawValue)
        Defaults[.hiddenNotchTabs] = hiddenIds
    }

    /// Repair `currentView` after any path that can orphan it: module
    /// toggles bypass setHidden, and the coordinator's default-view policy
    /// (applyDefaultViewOnOpen) calls in here as its last step. No-op while
    /// the shown view's tab is still visible. `coordinator` defaults to the
    /// app's; tests pass a private instance (GW-472).
    @MainActor
    static func ensureCurrentViewVisible(coordinator: GhostwireViewCoordinator = .shared) {
        let visible = currentlyVisible
        guard !visible.contains(where: { $0.view == coordinator.currentView }),
              let fallback = visible.first else { return }
        coordinator.currentView = fallback.view
    }
}
