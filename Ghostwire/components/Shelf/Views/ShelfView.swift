//
//  ShelfView.swift
//  Ghostwire
//
//  GW-218: the Shelf tab now hosts ONE unified card feed (UnifiedCardRow) over
//  both the saved Shelf items and the rolling clipboard history. The old "Drop
//  files here" hero + the separate clipboard swap-view are retired — copy is the
//  primary way in, drag is the demoted "or drag here" affordance in the row.
//

import AppKit
import SwiftUI

struct ShelfView: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var coordinator = GhostwireViewCoordinator.shared

    var body: some View {
        UnifiedCardRow()
            .environmentObject(vm)
            // The openClipboardHistory hotkey already navigates to this tab; the
            // unified feed *is* the clipboard surface now, so we just clear the
            // request. GW-213 (commit 2) hooks row focus in here.
            .onAppear { consumeClipboardRequest() }
            .onChange(of: coordinator.requestClipboardHistory) { consumeClipboardRequest() }
    }

    private func consumeClipboardRequest() {
        guard coordinator.requestClipboardHistory else { return }
        coordinator.requestClipboardHistory = false
    }
}
