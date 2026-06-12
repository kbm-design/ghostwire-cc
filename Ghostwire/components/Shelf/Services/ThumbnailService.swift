//
//  ThumbnailService.swift
//  Ghostwire
//
//

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [String: NSImage] = [:]
    private var pendingRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared

    private init() {}
    
    /// `iconMode` true (default) renders the QuickLook *file-icon* look — a white
    /// document page with a border/shadow, fine for small shelf tiles. Pass
    /// `false` for an edge-to-edge content thumbnail with no white frame (GW-218
    /// flush image cards).
    func thumbnail(for url: URL, size: CGSize, iconMode: Bool = true) async -> NSImage? {
        let cacheKey = "\(url.path)_\(size.width)x\(size.height)_\(iconMode)"

        if let cached = cache[cacheKey] {
            return cached
        }

        if let pending = pendingRequests[cacheKey] {
            return await pending.value
        }

        let task = Task<NSImage?, Never> {
            let thumbnail = await generateQuickLookThumbnail(for: url, size: size, iconMode: iconMode)
            if let thumbnail = thumbnail {
                cache[cacheKey] = thumbnail
            }
            pendingRequests[cacheKey] = nil
            return thumbnail
        }
        
        pendingRequests[cacheKey] = task
        return await task.value
    }
    
    func clearCache() {
        cache.removeAll()
    }
    
    func clearCache(for url: URL) {
        cache = cache.filter { !$0.key.starts(with: url.path) }
    }
    
    // MARK: - Private Methods
    
    private func generateQuickLookThumbnail(for url: URL, size: CGSize, iconMode: Bool) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }

        return await url.accessSecurityScopedResource { scopedURL in
            NSLog("🔐 ThumbnailService: obtaining security scope for \(scopedURL.path)")
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                // `.thumbnail` is the raw content rep (no white file-icon frame);
                // `.all` lets it fall back to the decorated icon look.
                representationTypes: iconMode ? .all : .thumbnail
            )
            request.iconMode = iconMode

            return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                thumbnailGenerator.generateBestRepresentation(for: request) { representation, error in
                    if let rep = representation {
                        NSLog("🔍 ThumbnailService: generated thumbnail for \(scopedURL.path)")
                        continuation.resume(returning: rep.nsImage)
                    } else {
                        if let err = error { 
                            NSLog("⚠️ ThumbnailService: thumbnail error for \(scopedURL.path): \(err.localizedDescription)") 
                        }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension QLThumbnailRepresentation {
    var nsImage: NSImage {
        return NSImage(cgImage: self.cgImage, size: self.cgImage.size)
    }
}

extension CGImage {
    var size: NSSize {
        return NSSize(width: self.width, height: self.height)
    }
}
