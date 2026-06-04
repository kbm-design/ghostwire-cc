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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agents: return "Agents"
        case .dashboard: return "Dashboard"
        case .shelf: return "Shelf"
        }
    }

    var icon: String {
        switch self {
        case .agents: return "terminal.fill"
        case .dashboard: return "square.grid.2x2"
        case .shelf: return "tray.fill"
        }
    }

    var view: NotchViews {
        switch self {
        case .agents: return .buddy
        case .dashboard: return .home
        case .shelf: return .shelf
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
    /// Never returns empty: if everything is hidden, falls back to the full order.
    static func visibleTabs(order: [NotchTab], hidden: Set<String>, shelfEnabled: Bool) -> [NotchTab] {
        let visible = order.filter { tab in
            guard !hidden.contains(tab.rawValue) else { return false }
            return tab != .shelf || shelfEnabled
        }
        return visible.isEmpty ? order : visible
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

    /// Hide/show a tab. Refuses to hide the last visible tab; if the
    /// currently shown view loses its tab, falls back to the first visible.
    @MainActor
    static func setHidden(_ tab: NotchTab, _ hidden: Bool) {
        var hiddenIds = Defaults[.hiddenNotchTabs]
        if hidden {
            let remaining = currentlyVisible.filter { $0 != tab }
            guard !remaining.isEmpty else { return }
            hiddenIds.insert(tab.rawValue)
            Defaults[.hiddenNotchTabs] = hiddenIds
            let coordinator = GhostwireViewCoordinator.shared
            if coordinator.currentView == tab.view, let fallback = currentlyVisible.first {
                coordinator.currentView = fallback.view
            }
        } else {
            hiddenIds.remove(tab.rawValue)
            Defaults[.hiddenNotchTabs] = hiddenIds
        }
    }
}
