import Combine
import SwiftUI

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class AgentPanelViewModel: ObservableObject {
    @Published var contentType: NotchContentType = .instances

    private var currentChatSession: SessionState?

    func showChat(for session: SessionState) {
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    func restoreChatIfNeeded() {
        if let chatSession = currentChatSession {
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func saveChatState() {
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
    }

    // MARK: - Composer drafts (GW-320)

    /// Unsent reply text, per session. `ChatView`'s `inputText` is view state, so
    /// it dies every time the view is torn down — backing out to the session list,
    /// or the notch auto-dismissing on dwell (GW-264). Losing a half-typed reply
    /// to an incidental dismiss is a real loss when the whole point of the surface
    /// is catching you mid-context, so drafts live here instead and outlive the view.
    private var drafts: [String: String] = [:]

    func draft(for sessionId: String) -> String {
        drafts[sessionId] ?? ""
    }

    func setDraft(_ text: String, for sessionId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = text
        }
    }
}
