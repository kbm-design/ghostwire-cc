//
//  ToolSearch.swift
//  Ghostwire
//
//  GW-184: the gateway's search fallback. Tools outside the working set stay
//  reachable: search_tools(query) ranks the full downstream catalog by how well
//  each tool's name + description matches the query and returns the top hits —
//  schema intact, so the agent can call_tool without a second round-trip.
//

import Foundation
import MCP

enum ToolSearch {
    /// Rank `catalog` against `query`; return the best `limit` matches. A name
    /// hit weighs more than a description hit. Tools that match no query token
    /// are excluded entirely.
    static func search(query: String, catalog: [Tool], limit: Int) -> [Tool] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        let scored = catalog.enumerated().compactMap { index, tool -> (tool: Tool, score: Int, index: Int)? in
            let name = tool.name.lowercased()
            let desc = (tool.description ?? "").lowercased()
            var score = 0
            for token in tokens {
                if name.contains(token) { score += 2 }
                if desc.contains(token) { score += 1 }
            }
            return score > 0 ? (tool, score, index) : nil
        }

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map(\.tool)
    }

    /// Split on any non-alphanumeric so `linear_create_issue` and
    /// `"create issue"` both tokenize to `["create", "issue"]`-style terms.
    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
