//
//  ShelfItemView.swift
//  Ghostwire
//
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var coordinator = GhostwireViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    // GW-210: swap the drag-tile strip out for the clipboard-history list when
    // the access row (or the openClipboardHistory hotkey) asks for it.
    @State private var showingClipboard = false

    var body: some View {
        Group {
            if showingClipboard {
                ClipboardHistoryView {
                    withAnimation(.easeInOut(duration: 0.2)) { showingClipboard = false }
                }
            } else {
                shelfContent
            }
        }
        // The openClipboardHistory hotkey routes here via the coordinator: it
        // already navigated to the Shelf tab, this lands on the clipboard view.
        .onAppear { consumeClipboardRequest() }
        .onChange(of: coordinator.requestClipboardHistory) { consumeClipboardRequest() }
    }

    private func consumeClipboardRequest() {
        guard coordinator.requestClipboardHistory else { return }
        coordinator.requestClipboardHistory = false
        withAnimation(.easeInOut(duration: 0.2)) { showingClipboard = true }
    }

    private var shelfContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                FileShareView()
                    .aspectRatio(1, contentMode: .fit)
                    .environmentObject(vm)
                panel
                    .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                        handleDrop(providers: providers)
                    }
            }

            ClipboardHistoryAccessRow {
                withAnimation(.easeInOut(duration: 0.2)) { showingClipboard = true }
            }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}
