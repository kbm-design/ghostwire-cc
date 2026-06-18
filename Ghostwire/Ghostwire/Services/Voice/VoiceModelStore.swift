//
//  VoiceModelStore.swift
//  Ghostwire
//
//  GW-229: tracks the download/load state of each on-device speech model so the
//  Settings UI can show "Download / Downloading… / Downloaded ✓ / Failed" and
//  the record flow can show "Preparing…" instead of a silent wait. "Downloaded"
//  is persisted (Defaults) so it survives relaunch without re-probing disk.
//

import Combine
import Defaults
import Foundation

@MainActor
final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed
    }

    @Published private(set) var states: [String: State] = [:]

    private init() {
        let downloaded = Set(Defaults[.voiceDownloadedModels])
        for model in VoiceModel.allCases {
            states[model.rawValue] = downloaded.contains(model.rawValue) ? .ready : .notDownloaded
        }
    }

    func state(_ model: VoiceModel) -> State { states[model.rawValue] ?? .notDownloaded }

    func setDownloading(_ model: VoiceModel) { states[model.rawValue] = .downloading }

    func setReady(_ model: VoiceModel) {
        states[model.rawValue] = .ready
        if !Defaults[.voiceDownloadedModels].contains(model.rawValue) {
            Defaults[.voiceDownloadedModels].append(model.rawValue)
        }
    }

    func setFailed(_ model: VoiceModel) { states[model.rawValue] = .failed }
}
