//
//  ContextModels.swift
//  Ghostwire
//
//  GW-172 — Tier-0 ambient spine. The value types the frontmost-app observer
//  produces and the context store persists. APP IDENTITY ONLY — no window
//  titles, no content (those are Tier-1, GW-182+). Pure structs so the streak
//  + filter rules are unit-testable without AppKit.
//
//  SILENT phase: these are collected + stored for Ghostwire's OWN future
//  surfacing (ranking GW-182, display GW-214). Local-only — this signal is
//  never narrated to a cloud agent (see project-moat-guardrail / privacy model).
//

import Foundation

/// Point-in-time observation of the user's foreground context.
struct ContextSnapshot: Equatable {
    let bundleID: String
    let appName: String
    /// System-wide idle seconds at capture (any-event; CGEventSource — no AX).
    let idleSeconds: TimeInterval
    let capturedAt: Date
}

/// The equality key for "has context meaningfully changed". `bundleID` only for
/// now — windowTitle/tabHost are Tier-1 (GW-182+) and deliberately absent.
struct ContextFingerprint: Equatable {
    let bundleID: String

    init(bundleID: String) { self.bundleID = bundleID }
    init(_ snapshot: ContextSnapshot) { self.bundleID = snapshot.bundleID }
}

/// One streak of continuous attention on the same fingerprint. Extend-don't-
/// append: a matching tick moves `end`/`idleAtEnd` forward in place rather than
/// creating a new event (see `ContextStreak.folding`).
struct ContextEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let bundleID: String
    let appName: String
    let start: Date
    private(set) var end: Date
    /// Idle seconds sampled at the streak's trailing edge — lets downstream back
    /// AFK time out of focus/dwell math.
    private(set) var idleAtEnd: TimeInterval

    nonisolated init(
        id: UUID,
        bundleID: String,
        appName: String,
        start: Date,
        end: Date,
        idleAtEnd: TimeInterval
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.start = start
        self.end = end
        self.idleAtEnd = idleAtEnd
    }

    /// Wall-clock span of the streak.
    var wallSeconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Active time = wall − clamped idle. The trailing idle reading can't exceed
    /// the streak's own wall span (a longer idle means the user was away before
    /// this streak began — which the max-gap rule already split off). This is a
    /// point-sample approximation, honest enough for Tier-0 dwell math.
    var activeSeconds: TimeInterval { max(0, wallSeconds - min(idleAtEnd, wallSeconds)) }

    /// Copy with the trailing edge advanced — events are otherwise immutable.
    nonisolated func extending(to newEnd: Date, idleAtEnd newIdle: TimeInterval) -> ContextEvent {
        var copy = self
        copy.end = max(end, newEnd)
        copy.idleAtEnd = newIdle
        return copy
    }
}
