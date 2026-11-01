// swiftlint:disable all
import UIKit

/// "Save audio (M4A)" for a video that is already downloaded: the sound is
/// extracted from the saved file, so it works offline and costs no extra
/// transfer.
extension DownloadMenu {
    static func audioExportItem(
        _ video: Video,
        from presenter: UIViewController,
        anchor: UIView
    ) -> PlayerMenuItem {
        PlayerMenuItem(
            title: WebMediaText.text("Save audio (M4A)", "Lưu âm thanh (M4A)"),
            iconName: "icon_share"
        ) {
            exportAudio(video, from: presenter, anchor: anchor)
        }
    }

    /// "Download audio (M4A)": fetches only the audio track, no video, and
    /// hands the finished .m4a to the share sheet ("Save to Files").
    static func audioDownloadItem(
        _ video: Video,
        from presenter: UIViewController,
        anchor: UIView
    ) -> PlayerMenuItem {
        PlayerMenuItem(
            title: WebMediaText.text(
                "Download audio (M4A)", "Tải âm thanh (M4A)"
            ),
            iconName: "icon_download"
        ) {
            downloadAudio(video, from: presenter, anchor: anchor)
        }
    }

    static func downloadAudio(
        _ video: Video,
        from presenter: UIViewController,
        anchor: UIView
    ) {
        guard !DownloadStatus.of(video.id).isActive else {
            audioToast(
                WebMediaText.text("Already in the queue", "Đã có trong hàng đợi"),
                in: presenter
            )
            return
        }
        audioToast(
            WebMediaText.text("Downloading audio…", "Đang tải âm thanh…"),
            in: presenter
        )
        VideoDownloader.shared.audioOption(for: video.id) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let option):
                    startAudioDownload(
                        video, option: option, from: presenter, anchor: anchor
                    )
                case .failure(let error):
                    AppLog.downloads("audio options failed: \(error)")
                    audioToast(
                        error.localizedDescription, in: presenter, isError: true
                    )
                }
            }
        }
    }

    private static func startAudioDownload(
        _ video: Video,
        option: DownloadOption,
        from presenter: UIViewController,
        anchor: UIView
    ) {
        VideoDownloader.shared.start(video: video, option: option) { result in
            switch result {
            case .success(let file):
                shareAudio(file, from: presenter, anchor: anchor)
            case .failure(let error):
                AppLog.downloads("audio job failed: \(error)")
                audioToast(
                    error.localizedDescription, in: presenter, isError: true
                )
            }
        }
    }

    /// The screen that asked may be gone by the time a download ends, so the
    /// sheet falls back to whatever is on top.
    private static func shareAudio(
        _ file: URL,
        from presenter: UIViewController,
        anchor: UIView
    ) {
        let host = presenter.viewIfLoaded?.window != nil
            ? presenter
            : topViewController()
        guard let host else {
            return
        }
        let activity = UIActivityViewController(
            activityItems: [file], applicationActivities: nil
        )
        if anchor.window != nil {
            VideoActionMenu.anchorPopover(activity, to: anchor)
        } else if let popover = activity.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(
                x: host.view.bounds.midX, y: host.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }
        host.present(activity, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.windows
            .first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }

    private static func audioToast(
        _ text: String,
        in presenter: UIViewController,
        isError: Bool = false
    ) {
        guard presenter.viewIfLoaded?.window != nil else {
            return
        }
        ToastView.show(text, in: presenter.view, isError: isError)
    }

    static func exportAudio(
        _ video: Video,
        from presenter: UIViewController,
        anchor: UIView
    ) {
        let source = DownloadStore.videoFile(for: video.id)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        ToastView.show(
            WebMediaText.text("Preparing audio…", "Đang chuẩn bị âm thanh…"),
            in: presenter.view
        )
        let name = (exportName(for: video) as NSString).deletingPathExtension
        AudioExporter.exportM4A(from: source, name: name) { result in
            switch result {
            case .success(let file):
                let activity = UIActivityViewController(
                    activityItems: [file], applicationActivities: nil
                )
                VideoActionMenu.anchorPopover(activity, to: anchor)
                presenter.present(activity, animated: true)
            case .failure(let error):
                AppLog.downloads("audio export failed: \(error)")
                ToastView.show(
                    error.localizedDescription,
                    in: presenter.view,
                    isError: true
                )
            }
        }
    }
}

// swiftlint:enable all
