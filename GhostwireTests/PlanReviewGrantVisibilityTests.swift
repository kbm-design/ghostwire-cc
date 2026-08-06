//
//  PlanReviewGrantVisibilityTests.swift
//  GhostwireTests
//
//  GW-362 defect 1. `allowedPromptsBlock` used to be the last child *inside*
//  `ChatPlanReviewBar`'s capped plan scroller (`planMaxHeight` = 200 in the
//  notch, 460 detached). On any plan longer than the cap it scrolled out of
//  view while Accept stayed visible and enabled, so the user could accept a
//  batch permission grant they were never shown — the one failure
//  `docs/interaction-model-payloads.md:83` calls out as the reason the block
//  is "a required render element".
//
//  The defect is structural — which subtree the grants live in — so the test
//  is structural too. SwiftUI encodes a view's composition in its static type,
//  so asserting on the type of the plan scroller's content is a real check on
//  where the grants sit, not a restatement of the source. Move the block back
//  inside the scroller and `planScrollerContent`'s type grows an
//  `AllowedPromptsBlock` and this fails.
//

import AppKit
import SwiftUI
import XCTest
@testable import Ghostwire

final class PlanReviewGrantVisibilityTests: XCTestCase {

    /// A plan far longer than either `planMaxHeight` (200 notch / 460 window),
    /// carrying grants — the exact combination that produced the defect.
    private func longPlanWithGrants() -> ExitPlanModeRequest {
        let body = (1...80)
            .map { "- step \($0): rewrite another file in the package\n" }
            .joined()
        return ExitPlanModeRequest(
            plan: "# Plan: a long one\n\n\(body)",
            planFilePath: "/Users/x/.claude/plans/long.md",
            allowedPrompts: [
                ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "npm test"),
                ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "rm -rf build/"),
                ExitPlanModeAllowedPrompt(tool: "Write", prompt: "src/**"),
            ]
        )
    }

    private func bar(for request: ExitPlanModeRequest) -> ChatPlanReviewBar {
        ChatPlanReviewBar(
            request: request,
            agentName: "Claude",
            agentTint: .orange,
            onAccept: { _ in },
            onRevise: { _, _ in },
            onGoToTerminal: {}
        )
    }

    /// The regression itself: nothing inside the height-capped plan scroller
    /// may be the grant block. Only the plan was ever meant to be capped.
    func testGrantBlockIsNotInsideTheCappedPlanScroller() {
        let subject = bar(for: longPlanWithGrants())
        let scrollerContent = String(describing: type(of: subject.planScrollerContent))

        XCTAssertFalse(
            scrollerContent.contains("AllowedPromptsBlock"),
            """
            allowedPrompts render inside the capped plan scroller, so a long \
            plan hides the batch grant while Accept stays enabled (GW-362). \
            Scroller content type: \(scrollerContent)
            """
        )
    }

    /// …and the other half: it is still rendered. A test that only forbids the
    /// block inside the scroller would also pass if the block were deleted.
    func testGrantBlockRendersAboveThePlanForARequestThatCarriesGrants() {
        let subject = bar(for: longPlanWithGrants())
        let body = String(describing: type(of: subject.body))

        guard let grantsAt = body.range(of: "AllowedPromptsBlock") else {
            return XCTFail("The grant block is not rendered at all. Body: \(body)")
        }
        guard let scrollerAt = body.range(of: "ScrollView") else {
            return XCTFail("The plan scroller is gone. Body: \(body)")
        }
        XCTAssertTrue(
            grantsAt.lowerBound < scrollerAt.lowerBound,
            "The grant block must be pinned above the plan scroller. Body: \(body)"
        )
    }

    // MARK: - The grant list must never render at zero height (review finding 3)

    /// `AllowedPromptsBlock` frames its scroller to the *measured* content
    /// height, which starts at 0. Without a fallback the grants get a 0pt
    /// viewport on the first layout pass — only the count label visible, Accept
    /// already live — and a zero-height ScrollView may never emit the geometry
    /// preference that would fix it. This pins the fallback.
    func testGrantListHeightIsNeverZeroBeforeMeasurement() {
        let block = AllowedPromptsBlock(
            grants: [
                ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "npm test"),
                ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "rm -rf build/"),
            ],
            listMaxHeight: 120
        )
        // listContentHeight is still 0 here — nothing has laid out yet.
        XCTAssertGreaterThan(
            block.listHeight, 0,
            "The grant list gets a zero-height viewport before measurement (GW-362 finding 3)"
        )
        XCTAssertLessThanOrEqual(block.listHeight, 120, "must still respect the cap")
    }

    /// The estimate must stay bounded by the cap, or a long grant list would
    /// push Accept off the fixed-height notch panel on the first frame.
    func testGrantListEstimateIsCappedForALongList() {
        let many = (1...40).map {
            ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "command number \($0)")
        }
        let block = AllowedPromptsBlock(grants: many, listMaxHeight: 120)
        XCTAssertEqual(block.listHeight, 120, accuracy: 0.5)
    }

    /// Rendered, not inferred: lay the block out in a real host view and prove
    /// the grant rows occupy height rather than collapsing to the label.
    @MainActor
    func testGrantRowsActuallyOccupyHeightWhenLaidOut() {
        func renderedHeight(grants: [ExitPlanModeAllowedPrompt]) -> CGFloat {
            let host = NSHostingView(
                rootView: AllowedPromptsBlock(grants: grants, listMaxHeight: 120)
                    .frame(width: 560)
            )
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        let labelOnly = renderedHeight(grants: [])
        let withGrants = renderedHeight(grants: [
            ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "npm run build"),
            ExitPlanModeAllowedPrompt(tool: "Bash", prompt: "rm -rf dist/ && npm run deploy"),
            ExitPlanModeAllowedPrompt(tool: "Write", prompt: "src/pages/**"),
        ])

        XCTAssertGreaterThan(
            withGrants, labelOnly,
            """
            Three grants rendered no taller than the bare label, so the rows are \
            collapsed and the user sees a count with nothing under it. \
            label-only: \(labelOnly)  with-grants: \(withGrants)
            """
        )
    }

    /// The other direction: don't "fix" this by pinning everything. The plan
    /// itself must stay inside the scroller — that cap is what keeps a 400-line
    /// plan from pushing Accept off a fixed-height notch panel in the first place.
    func testPlanItselfStaysInsideTheCappedScroller() {
        let subject = bar(for: longPlanWithGrants())
        let scrollerContent = String(describing: type(of: subject.planScrollerContent))

        XCTAssertTrue(
            scrollerContent.contains("PlanMarkdownView"),
            "The plan must still be the scroller's content. Got: \(scrollerContent)"
        )
    }
}
