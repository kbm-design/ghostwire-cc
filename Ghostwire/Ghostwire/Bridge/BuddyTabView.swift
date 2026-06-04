import SwiftUI

struct BuddyTabView: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var bridge = GhostwireSessionBridge.shared
    @ObservedObject private var panelVM = GhostwireSessionBridge.shared.panelViewModel
    @ObservedObject private var usageService = UsageService.shared
    @ObservedObject private var codexUsageService = CodexUsageService.shared
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false
    /// GW-151: which agent's usage detail replaces the sessions list (nil = list)
    @State private var usageDetailAgent: String?
    /// GW-151: meter slot order - first agent to come alive keeps slot 1
    @State private var agentOrder: [String] = []

    private var isInChat: Bool {
        if case .chat = panelVM.contentType { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if isInChat, case .chat(let session) = panelVM.contentType {
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: bridge.sessionMonitor,
                    viewModel: panelVM
                )
                .onHover { hovering in
                    updateSuppression(for: hovering)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                homeContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isInChat)
        .onDisappear {
            updateSuppression(for: false)
            panelVM.saveChatState()
            panelVM.exitChat()
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = usageDetailAgent, let display = usageDisplay(for: agent) {
                AgentUsageDetailView(agent: agent, display: display) {
                    withAnimation(.easeInOut(duration: 0.2)) { usageDetailAgent = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                usageSummaryRow

                ClaudeInstancesView(
                    sessionMonitor: bridge.sessionMonitor,
                    viewModel: panelVM
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
        .onHover { hovering in
            updateSuppression(for: hovering)
        }
        .onAppear { syncAgentOrder() }
        .onChange(of: claudeMeterVisible) { _ in syncAgentOrder() }
        .onChange(of: codexMeterVisible) { _ in syncAgentOrder() }
    }

    // MARK: - GW-151 usage meters

    private var claudeMeterVisible: Bool {
        usageService.isAvailable && usageService.display != nil
    }

    /// Codex meter shows only when relevant: a live Codex session in the
    /// notch, or rollout activity within the current 5H window.
    private var codexMeterVisible: Bool {
        guard codexUsageService.display != nil else { return false }
        if sessions.contains(where: { $0.agent == "codex" }) { return true }
        if let last = codexUsageService.lastActivityDate {
            return Date().timeIntervalSince(last) < 5 * 3600
        }
        return false
    }

    private func usageDisplay(for agent: String) -> AgentUsageDisplay? {
        agent == "codex" ? codexUsageService.display : usageService.display
    }

    /// First agent to come alive keeps slot 1; slots never reshuffle while
    /// both meters are visible.
    private func syncAgentOrder() {
        for agent in ["claude", "codex"] {
            let visible = agent == "claude" ? claudeMeterVisible : codexMeterVisible
            if visible && !agentOrder.contains(agent) {
                agentOrder.append(agent)
            }
        }
        agentOrder.removeAll { agent in
            agent == "claude" ? !claudeMeterVisible : !codexMeterVisible
        }
    }

    private var visibleAgents: [String] {
        agentOrder.filter { usageDisplay(for: $0) != nil }
    }

    @ViewBuilder
    private var usageSummaryRow: some View {
        let agents = visibleAgents
        if agents.count == 1, let display = usageDisplay(for: agents[0]) {
            // Single agent → today's exact layout: Session left, Weekly right
            singleAgentRow(agent: agents[0], display: display)
        } else if agents.count > 1 {
            // Both agents → per-agent 5H bars, slot-stable, identity-tinted
            HStack(spacing: 12) {
                ForEach(agents, id: \.self) { agent in
                    if let display = usageDisplay(for: agent) {
                        agentSummaryBar(agent: agent, display: display)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func singleAgentRow(agent: String, display: AgentUsageDisplay) -> some View {
        switch display {
        case .quota(let fiveHour, let sevenDay):
            HStack(spacing: 12) {
                if let fh = fiveHour {
                    meterButton(agent: agent) {
                        UsageBar(
                            label: "Session",
                            percent: fh.utilization / 100,
                            detail: "\(Int(fh.utilization))%",
                            color: thresholdColor(fh.utilization, base: Self.legacyBarColor)
                        )
                    }
                }
                if let sd = sevenDay {
                    meterButton(agent: agent) {
                        UsageBar(
                            label: "Weekly",
                            percent: sd.utilization / 100,
                            detail: "\(Int(sd.utilization))%",
                            color: thresholdColor(sd.utilization, base: Self.legacyBarColor)
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
        case .tokens(let tokens):
            // API auth: static track + spend figure (fills toward a
            // user-set limit once GW-144 ships limit entry)
            meterButton(agent: agent) {
                UsageBar(
                    label: "Spend",
                    percent: 0,
                    detail: UsageFormat.tokenSummary(tokens),
                    color: AgentIdentity.tint(for: agent)
                )
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func agentSummaryBar(agent: String, display: AgentUsageDisplay) -> some View {
        let label = agent.prefix(1).uppercased() + agent.dropFirst()
        let tint = AgentIdentity.tint(for: agent)

        meterButton(agent: agent) {
            switch display {
            case .quota(let fiveHour, let sevenDay):
                // 5H is the bar; 7D surfaces only when it's about to bite
                let fh = fiveHour?.utilization ?? 0
                UsageBar(
                    label: label,
                    percent: fh / 100,
                    detail: "\(Int(fh))%",
                    color: thresholdColor(fh, base: tint),
                    flag: (sevenDay?.utilization ?? 0) >= 90
                        ? "7D \(Int(sevenDay?.utilization ?? 0))%" : nil
                )
            case .tokens(let tokens):
                UsageBar(
                    label: label,
                    percent: 0,
                    detail: UsageFormat.tokenSummary(tokens),
                    color: tint
                )
            }
        }
    }

    /// Click target wrapper: whole bar tappable → that agent's detail view
    private func meterButton<Content: View>(agent: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { usageDetailAgent = agent }
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let legacyBarColor = Color(red: 0.35, green: 0.55, blue: 1.0)

    private func thresholdColor(_ utilization: Double, base: Color) -> Color {
        utilization > 80 ? .red : utilization > 60 ? .yellow : base
    }

    private var sessions: [SessionState] { bridge.sessionMonitor.instances }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

struct UsageBar: View {
    let label: String
    let percent: Double
    let detail: String
    let color: Color
    /// GW-151: red urgency flag (e.g. "7D 92%") - only shown when set
    var flag: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let flag {
                    Text(flag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * percent))
                }
            }
            .frame(height: 4)
        }
    }
}
