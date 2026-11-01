import AVFoundation
import Foundation

// MARK: - Running one job

extension VideoDownloader {
    /// Everything already written across both parts, so a resumed job reports
    /// the progress it actually stands at rather than starting from zero.
    func bytesAlreadySaved(videoId: String) -> Int64 {
        [videoPartFile(videoId), audioPartFile(videoId)]
            .map(Self.bytesOnDisk)
            .reduce(0, +)
    }

    func videoPartFile(_ videoId: String) -> URL {
        DownloadStore.partFile(
            for: videoId, named: "video" + DownloadStore.partSuffix
        )
    }

    func audioPartFile(_ videoId: String) -> URL {
        DownloadStore.partFile(
            for: videoId, named: "audio" + DownloadStore.partSuffix
        )
    }

    func fetchTracks(videoId: String, option: DownloadOption) {
        if option.audioOnly {
            fetchAudioOnly(videoId: videoId, option: option)
            return
        }
        let videoPart = videoPartFile(videoId)
        let audioPart = audioPartFile(videoId)
        download(
            from: option.video.url,
            to: videoPart,
            size: option.video.contentLength
        ) { [weak self] error in
            if let error {
                self?.fail(videoId: videoId, error: error)
                return
            }
            self?.fetchAudio(
                videoId: videoId,
                option: option,
                parts: (videoPart, audioPart)
            )
        }
    }

    private func fetchAudio(
        videoId: String,
        option: DownloadOption,
        parts: (video: URL, audio: URL)
    ) {
        download(
            from: option.audio.url,
            to: parts.audio,
            size: option.audio.contentLength
        ) { [weak self] error in
            if let error {
                self?.fail(videoId: videoId, error: error)
                return
            }
            self?.mux(videoId: videoId, option: option, parts: parts)
        }
    }

    // MARK: - Audio only

    private func fetchAudioOnly(videoId: String, option: DownloadOption) {
        download(
            from: option.audio.url,
            to: audioPartFile(videoId),
            size: option.audio.contentLength
        ) { [weak self] error in
            if let error {
                self?.fail(videoId: videoId, error: error)
                return
            }
            self?.exportAudioOnly(videoId: videoId, option: option)
        }
    }

    /// Wraps the downloaded track in a composition clamped to the length the
    /// server states: a raw adaptive MP4 can read back twice as long as it
    /// is (see the note in `VideoDownloader+Mux`), and exporting it as it
    /// is would pad the file with silence.
    private func exportAudioOnly(videoId: String, option: DownloadOption) {
        markMuxing()
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: audioPartFile(videoId))
        guard let source = asset.tracks(withMediaType: .audio).first,
              let target = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            fail(videoId: videoId, error: DownloadError.noTracks)
            return
        }
        var range = source.timeRange
        if let ms = option.audio.approxDurationMs, ms > 0 {
            let stated = CMTime(value: CMTimeValue(ms), timescale: 1_000)
            range = CMTimeRange(
                start: range.start,
                duration: CMTimeMinimum(stated, range.duration)
            )
        }
        do {
            try target.insertTimeRange(range, of: source, at: .zero)
        } catch {
            fail(videoId: videoId, error: error)
            return
        }
        let title = activeVideo.map {
            (DownloadMenu.exportName(for: $0) as NSString)
                .deletingPathExtension
        } ?? videoId
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(title + ".m4a")
        exportAudio(
            composition,
            to: output,
            videoId: videoId,
            presets: [
                AVAssetExportPresetPassthrough,
                AVAssetExportPresetAppleM4A
            ]
        )
    }

    /// Passthrough first (AAC straight into an M4A, no re-encode), the Apple
    /// M4A preset when the system will not take that combination.
    private func exportAudio(
        _ asset: AVAsset,
        to output: URL,
        videoId: String,
        presets: [String]
    ) {
        guard let preset = presets.first else {
            fail(videoId: videoId, error: DownloadError.export)
            return
        }
        let rest = Array(presets.dropFirst())
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: preset
        ), session.supportedFileTypes.contains(.m4a) else {
            exportAudio(asset, to: output, videoId: videoId, presets: rest)
            return
        }
        session.outputURL = output
        session.outputFileType = .m4a
        session.exportAsynchronously { [weak self] in
            if session.status == .completed {
                // The raw track is no longer needed and the card has to go:
                // this download is not kept in the library.
                DownloadStore.remove(videoId)
                AppLog.downloads("audio finished \(videoId)")
                self?.finishJob(reporting: .success(output))
            } else if !rest.isEmpty {
                self?.exportAudio(
                    asset, to: output, videoId: videoId, presets: rest
                )
            } else {
                self?.fail(
                    videoId: videoId,
                    error: session.error ?? DownloadError.export
                )
            }
        }
    }

    func fail(videoId: String, error: Error) {
        let cancelled = cancellation?.isCancelled == true
        guard !cancelled else {
            DownloadStore.removeParts(for: videoId)
            finishJob(reporting: nil)
            return
        }
        AppLog.downloads("failed \(videoId): \(error)")
        guard !retryLater(videoId: videoId) else {
            return
        }
        // Only now are the parts worth dropping: a retry would have resumed
        // from them.
        DownloadStore.removeParts(for: videoId)
        DownloadStore.markFailed(videoId)
        finishJob(reporting: .failure(error))
    }
}
