//
//  AudioPlayer.swift
//  buddi
//
//

import Foundation
import AppKit

class AudioPlayer {
    func play(fileName: String, fileExtension: String) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else { return }
        NSSound(contentsOf: url, byReference: false)?.play()
    }
}
