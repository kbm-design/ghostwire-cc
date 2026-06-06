//
//  SendToAgentPicker.swift
//  Ghostwire
//
//  GW-163: the disambiguation step for send-to-agent. Shown only when several
//  live agents are addressable and none is focused (AgentTargetResolver's
//  `.candidates`). Lists the candidates with InstanceRow's visual vocabulary —
//  identity dot (agent tint) + title + folder — compact, one tap to inject.
//
//  Quiet by house style: a small panel overlaid on the open notch, tap-outside
//  to dismiss. No modal, no alert.
//

import SwiftUI

struct SendToAgentPicker: View {
    let candidates: [SessionState]
    let onPick: (SessionState) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Tap-outside scrim — dismisses without choosing.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text("Send to")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { session in
                            PickerRow(session: session) { onPick(session) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 180)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 260)
            .shadow(color: .black.opacity(0.5), radius: 12)
        }
        .transition(.opacity)
    }
}

// MARK: - Row (InstanceRow vocabulary, compact)

private struct PickerRow: View {
    let session: SessionState
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Identity dot — agent tint (matches InstanceRow / GW-138).
                Circle()
                    .fill(AgentIdentity.tint(for: session.agent))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.folderName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
