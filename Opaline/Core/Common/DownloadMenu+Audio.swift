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
