//
//  UpdateStatusModel.swift
//  Ghostwire
//
//  Sparkle's result, published for the sidebar footer. The footer says the app's
//  version and whether it's current — the two things "Check for Updates…" used
//  to be the only way to learn, back when it lived in the titlebar.
//
//  Deliberately has no "checking…" state and no persistence: before Sparkle has
//  reported anything the row renders NOTHING rather than a guess. A stale
//  "Up to date" restored from disk is worse than no line at all — this row's
//  only job is to be true.
//

import Sparkle
import SwiftUI

@MainActor
final class UpdateStatusModel: NSObject, ObservableObject {
    enum Status: Equatable {
        /// Sparkle hasn't reported yet (or automatic checks are off) — render nothing.
        case unknown
        case upToDate
        case available(version: String?)
        case failed
    }

    static let shared = UpdateStatusModel()

    @Published private(set) var status: Status = .unknown

    private override init() { super.init() }
}

// Sparkle's delegate is an ObjC protocol with no actor annotation, so the
// conformance has to be nonisolated and hop to the main actor itself.
extension UpdateStatusModel: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.status = .available(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.status = .upToDate }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // A user cancelling their own check is not a failure to report.
        let cancelled = (error as NSError).code == Int(SUError.installationCanceledError.rawValue)
        Task { @MainActor in
            guard !cancelled else { return }
            self.status = .failed
        }
    }
}
