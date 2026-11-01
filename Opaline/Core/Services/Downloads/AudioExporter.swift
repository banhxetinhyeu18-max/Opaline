import AVFoundation
import Foundation

enum AudioExportError: LocalizedError {
    case noAudio
    case failed

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return WebMediaText.text(
                "This file has no audio track", "Tệp này không có âm thanh"
            )
        case .failed:
            return WebMediaText.text(
                "Couldn't extract the audio", "Không tách được âm thanh"
            )
        }
    }
}

/// Pulls the sound out of a saved video as an M4A (AAC) file.
///
/// M4A rather than MP3 on purpose: iOS can encode AAC natively but ships no
/// MP3 encoder, so MP3 would mean bundling a third-party codec.
enum AudioExporter {
    /// The result lands in the temporary directory — the caller hands it to
    /// the share sheet ("Save to Files") right away.
    static func exportM4A(
        from source: URL,
        name: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: source)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            completion(.failure(AudioExportError.noAudio))
            return
        }
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            completion(.failure(AudioExportError.failed))
            return
        }
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let clean = name.components(separatedBy: banned).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent((clean.isEmpty ? "audio" : String(clean.prefix(80))) + ".m4a")
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status == .completed {
                    completion(.success(output))
                } else {
                    completion(.failure(session.error ?? AudioExportError.failed))
                }
            }
        }
    }
}
