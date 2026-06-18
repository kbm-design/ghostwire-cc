//
//  VoiceCaptureView.swift
//  Ghostwire
//
//  GW-229: the voice error overlay (mic/speech denied, or a model load
//  failure). Recording itself is non-modal — the notch header shows a stop
//  control while open (GhostwireHeader.NotchRecordingButton) and the ambient
//  indicator (ContentView.RecordingLiveActivity) while closed — so this overlay
//  is only ever an error.
//

import SwiftUI

struct VoiceCaptureView: View {
    @ObservedObject var vm: VoiceCaptureViewModel

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if vm.errorMessage != nil { vm.cancel() } }

            Group {
                if vm.errorMessage != nil {
                    errorBody
                } else {
                    preparingBody
                }
            }
            .frame(maxWidth: 300)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 12)
            .focusable()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                if vm.errorMessage != nil, press.key == .escape || press.key == .return {
                    vm.cancel(); return .handled
                }
                return .ignored
            }
        }
        .transition(.opacity)
        .onAppear { focused = true }
    }

    // MARK: - Preparing (cold model download/load before recording)

    private var preparingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing speech model…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            Text("First use downloads the on-device model (one time). It'll start recording when ready.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Error

    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("Voice capture")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            Text(vm.errorMessage ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            HStack {
                Spacer()
                Button("Dismiss") { vm.cancel() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
            }
            .padding(.horizontal, 4)
        }
    }
}
