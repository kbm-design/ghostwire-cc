//
//  ShelfView.swift
//  Ghostwire
//
//  GW-218: the Shelf tab now hosts ONE unified card feed (UnifiedCardRow) over
//  both the saved Shelf items and the rolling clipboard history. The old "Drop
//  files here" hero + the separate clipboard swap-view are retired — copy is the
//  primary way in, drag is the demoted "or drag here" affordance in the row.
//
//  The openClipboardHistory hotkey (GW-213) is handled inside UnifiedCardRow,
//  which grabs keyboard focus and seeds a selection; this view just hosts it.
//

import AppKit
import SwiftUI

struct ShelfView: View {
    @EnvironmentObject var vm: GhostwireViewModel

    var body: some View {
        UnifiedCardRow()
            .environmentObject(vm)
    }
}
