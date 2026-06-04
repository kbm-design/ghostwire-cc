//
//  TabSelectionView.swift
//  Ghostwire
//
//

import Defaults
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = GhostwireViewCoordinator.shared
    @State private var displayedView: NotchViews = GhostwireViewCoordinator.shared.currentView
    @Namespace var animation

    // Observed so the bar live-updates when settings change (GW-144)
    @Default(.notchTabOrder) private var tabOrder
    @Default(.hiddenNotchTabs) private var hiddenTabs
    @Default(.shelf) private var shelfEnabled

    private var visibleTabs: [NotchTab] {
        NotchTab.visibleTabs(
            order: NotchTab.sanitizedOrder(tabOrder),
            hidden: hiddenTabs,
            shelfEnabled: shelfEnabled
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                TabButton(label: tab.label, icon: tab.icon, selected: displayedView == tab.view) {
                    withAnimation(.smooth) {
                        displayedView = tab.view
                        coordinator.currentView = tab.view
                    }
                }
                .frame(height: 26)
                .foregroundStyle(tab.view == displayedView ? .white : .gray)
                .background {
                    if tab.view == displayedView {
                        Capsule()
                            .fill(Color(nsColor: .secondarySystemFill))
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    }
                }
            }
        }
        .clipShape(Capsule())
        .onAppear { displayedView = coordinator.currentView }
        .onChange(of: coordinator.currentView) { _, new in
            guard displayedView != new else { return }
            withAnimation(.smooth) { displayedView = new }
        }
    }
}

#Preview {
    GhostwireHeader().environmentObject(GhostwireViewModel())
}
