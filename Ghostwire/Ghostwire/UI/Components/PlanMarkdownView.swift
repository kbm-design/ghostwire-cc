//
//  PlanMarkdownView.swift
//  Ghostwire
//
//  GW-322 (State C — Plan review). Block-level markdown for a plan.
//
//  `GhostwireMarkdownText` renders with `.inlineOnlyPreservingWhitespace`, which
//  is right for a chat turn but wrong for a plan: every plan captured in GW-322
//  led with `#` headings and carried numbered steps and fenced code, and inline
//  parsing renders those as literal `#`, `1.` and ``` characters. Spec §4.1 says
//  the plan renders fully and literally — markdown rendering allowed, elision
//  not — so this adds the block layer and delegates each block's *inline* spans
//  back to `GhostwireMarkdownText`. Nothing about the shipped chat rendering
//  changes.
//
//  The parser is pure and `nonisolated` so it can be unit-tested without a view.
//

import SwiftUI

/// One parsed block of a plan.
enum PlanBlock: Equatable, Identifiable {
    case heading(level: Int, text: String)
    /// `marker` is the literal bullet or number the source used, so an ordered
    /// list keeps its own numbering rather than being renumbered from 1.
    case listItem(indent: Int, marker: String, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case rule
    case paragraph(String)

    var id: String {
        switch self {
        case .heading(let level, let text):        return "h\(level):\(text)"
        case .listItem(let i, let m, let t):       return "l\(i):\(m):\(t)"
        case .code(let lang, let text):            return "c\(lang ?? ""):\(text)"
        case .quote(let text):                     return "q:\(text)"
        case .rule:                                return "hr"
        case .paragraph(let text):                 return "p:\(text)"
        }
    }
}

enum PlanMarkdownParser {

    /// Split plan markdown into blocks.
    ///
    /// Deliberately small: headings, list items, fenced code, block quotes,
    /// horizontal rules, paragraphs. Anything it doesn't recognise falls through
    /// to `.paragraph` and is still rendered in full — the parser can degrade,
    /// but it must never drop a line.
    nonisolated static func parse(_ markdown: String) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var paragraph: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code runs verbatim, so it is checked before everything
            // else: a `#` inside a fence is a shell comment, not a heading.
            if var open = fence {
                if trimmed.hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language,
                                        text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let item = listItem(line: line, trimmed: trimmed) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence still has to render — the plan is never elided.
        if let open = fence {
            blocks.append(.code(language: open.language,
                                text: open.lines.joined(separator: "\n")))
        }
        flushParagraph()

        return blocks
    }

    // MARK: - Line classifiers

    private nonisolated static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == marker }) {
            return true
        }
        return false
    }

    private nonisolated static func heading(_ trimmed: String) -> PlanBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        // "####### x" is seven hashes — not a heading in CommonMark, and a
        // literal `#####…` divider line shouldn't silently become one either.
        guard hashes.count <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(hashes.count))
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return .heading(level: hashes.count,
                        text: rest.trimmingCharacters(in: .whitespaces))
    }

    private nonisolated static func listItem(line: String, trimmed: String) -> PlanBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return .listItem(indent: indent, marker: "•",
                             text: String(trimmed.dropFirst(marker.count)))
        }

        // "12. step" / "3) step" — keep the author's own number.
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard after.hasPrefix(". ") || after.hasPrefix(") ") else { return nil }
        return .listItem(indent: indent, marker: "\(digits).",
                         text: String(after.dropFirst(2)))
    }
}

// MARK: - View

/// Renders plan markdown as blocks. Inline spans (bold, italic, `code`, links)
/// still go through `GhostwireMarkdownText`, so emphasis reads the same here as
/// it does in the transcript.
struct PlanMarkdownView: View {
    let markdown: String

    private var blocks: [PlanBlock] { PlanMarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: PlanBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // The notch is 640 wide; the design system's 18pt Section role would
            // eat a plan's height budget in headings alone. Step down instead,
            // staying at or above `text/primary` weight so structure still reads.
            GhostwireMarkdownText(text,
                                  color: .white.opacity(0.95),
                                  fontSize: level <= 1 ? 14 : (level == 2 ? 13 : 12))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)

        case .listItem(let indent, let marker, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(minWidth: 14, alignment: .trailing)
                GhostwireMarkdownText(text, color: .white.opacity(0.85), fontSize: 12)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                }
                // Verbatim: a plan's code block is the thing being agreed to.
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 2)
                GhostwireMarkdownText(text, color: .white.opacity(0.65), fontSize: 12)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 2)

        case .paragraph(let text):
            GhostwireMarkdownText(text, color: .white.opacity(0.85), fontSize: 12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
