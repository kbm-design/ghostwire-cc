//
//  ShelfPersistenceService.swift
//  Ghostwire
//
//

import Foundation

// Access model types
@_exported import struct Foundation.URL


final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        // GW-248: canonical Application Support root is "Ghostwire" (UsageService
        // already uses it); the Shelf store missed the buddi→Ghostwire rename.
        let dir = support.appendingPathComponent("Ghostwire", isDirectory: true).appendingPathComponent("Shelf", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("items.json")

        // One-time, non-destructive migration off the legacy "buddi" dir: copy
        // the old store in only when we don't already have one, so existing held
        // items aren't orphaned and a re-run can't clobber newer data.
        let legacyFileURL = support
            .appendingPathComponent("buddi", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("items.json")
        if !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacyFileURL.path) {
            try? fm.copyItem(at: legacyFileURL, to: fileURL)
        }

        encoder.outputFormatting = [.prettyPrinted]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        
        // Try to decode as array first (normal case)
        if let items = try? decoder.decode([ShelfItem].self, from: data) {
            return items
        }
        
        // If array decoding fails, try to decode individual items
        do {
            // Parse as JSON array to get individual item data
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                print("⚠️ Shelf persistence file is not a valid JSON array")
                return []
            }
            
            var validItems: [ShelfItem] = []
            var failedCount = 0
            
            for (index, jsonItem) in jsonArray.enumerated() {
                do {
                    let itemData = try JSONSerialization.data(withJSONObject: jsonItem)
                    let item = try decoder.decode(ShelfItem.self, from: itemData)
                    validItems.append(item)
                } catch {
                    failedCount += 1
                    print("⚠️ Failed to decode shelf item at index \(index): \(error.localizedDescription)")
                }
            }
            
            if failedCount > 0 {
                print("📦 Successfully loaded \(validItems.count) shelf items, discarded \(failedCount) corrupted items")
            }
            
            return validItems
        } catch {
            print("❌ Failed to parse shelf persistence file: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ items: [ShelfItem]) {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            print("Failed to save shelf items: \(error.localizedDescription)")
        }
    }
}
