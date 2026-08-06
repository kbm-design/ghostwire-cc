//
//  GhostwireHeader.swift
//  Ghostwire
//
//

import Defaults
import SwiftUI

struct GhostwireHeader: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = GhostwireViewCoordinator.shared
    @ObservedObject var voice = VoiceCaptureViewModel.shared
    @StateObject var tvm = ShelfStateViewModel.shared

    // Observed so the bar live-updates when tab settings change (GW-144)
    @Default(.notchTabOrder) private var tabOrder
    @Default(.hiddenNotchTabs) private var hiddenTabs
    @Default(.shelf) private var shelfEnabled

    /// Tab bar needs ≥2 visible tabs. Legacy rule retained: while the Shelf
    /// tab is visible, the bar only appears once the shelf has items (or
    /// "always show tabs" is on). With Shelf hidden/disabled the remaining
    /// tabs still get a bar (legacy hid it entirely).
    private var shouldShowTabBar: Bool {
        let visible = NotchTab.visibleTabs(
            order: NotchTab.sanitizedOrder(tabOrder),
            hidden: hiddenTabs,
            shelfEnabled: shelfEnabled
        )
        guard visible.count >= 2 else { return false }
        if visible.contains(.shelf) {
            return !tvm.isEmpty || coordinator.alwaysShowTabs
        }
        return true
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if shouldShowTabBar {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    // GW-229: live recording control — a pulsing red dot that
                    // becomes a Stop (red square) on hover. Non-modal, so the
                    // notch stays usable while recording.
                    if voice.stage == .recording {
                        NotchRecordingButton { Task { await voice.stopRecording() } }
                    }
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        // GW-223: detach the Shelf into a full resizable window.
                        // Always shown while the notch is open — it's a destination
                        // opener, not a shelf-only action — in the same 30×30 capsule
                        // vocabulary as the gear/camera buttons.
                        // (In-notch expand is GW-222; this is the simple opener.)
                        NotchHeaderIconButton(systemName: "macwindow", help: "Open Shelf in window") {
                            DispatchQueue.main.async {
                                ShelfWindowController.shared.showWindow()
                            }
                        }
                        if Defaults[.showMirror] {
                            NotchHeaderIconButton(systemName: "web.camera", help: "Toggle camera preview") {
                                vm.toggleCameraPreview()
                            }
                        }
                        if Defaults[.settingsIconInNotch] {
                            NotchHeaderIconButton(systemName: "gear", help: "Open Settings") {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }
                        }
                        if Defaults[.showBatteryIndicator] {
                            GhostwireBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

/// GW-223: notch-header action button (detach / camera / settings). Dimmed to
/// grey at rest so it reads as an inactive affordance like the tabs, brightening
/// to full white on hover. Same 30×30 black capsule vocabulary as before.
private struct NotchHeaderIconButton: View {
    let systemName: String
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: systemName)
                        .foregroundColor(.white.opacity(hovering ? 1.0 : 0.5))
                        .padding()
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)

        // Only attach a tooltip when one is provided — .help("") shows a
        // blank tooltip bubble.
        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

/// GW-229: recording indicator in the notch header. At rest, a pulsing red dot;
/// on hover, a red square (Stop). Click stops the recording. Same 30×30 black
/// capsule vocabulary as the other header buttons.
private struct NotchRecordingButton: View {
    let onStop: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: onStop) {
            Capsule()
                .fill(hovering ? Color.red.opacity(0.18) : .black)
                .frame(width: 30, height: 30)
                .overlay {
                    // One shape that morphs dot → rounded square (smooth corner
                    // animation), so hover clearly reads as "this stops it".
                    RoundedRectangle(cornerRadius: hovering ? 2.5 : 5, style: .continuous)
                        .fill(Color.red)
                        .frame(width: hovering ? 11 : 10, height: hovering ? 11 : 10)
                        .opacity(hovering ? 1.0 : (pulse ? 1.0 : 0.45))
                }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering = $0 }
        .help("Stop recording")
        .animation(.easeInOut(duration: 0.18), value: hovering)
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

#Preview {
    GhostwireHeader().environmentObject(GhostwireViewModel())
}
