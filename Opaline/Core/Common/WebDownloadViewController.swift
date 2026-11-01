import UIKit

/// Download from a link: paste the address of a video/audio file, or of any
/// page that embeds one. The result goes to the share sheet ("Save to
/// Files", "Save Video", other apps); a video can also be saved as M4A.
final class WebDownloadViewController: UIViewController, UITextFieldDelegate {
    private let field = UITextField()
    private let startButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private var downloader: WebMediaDownloader?
    private var lastFile: URL?

    private var isRunning: Bool { downloader != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = WebMediaText.text("Download from link", "Tải từ liên kết")
        let theme = ThemeManager.shared
        view.backgroundColor = theme.background
        configureField(theme)
        configureButtons(theme)
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = theme.secondaryText
        statusLabel.text = WebMediaText.text(
            "Paste a link to a video or audio file (mp4, mov, mp3, m4a…) or to a "
                + "page that embeds one. Streaming (HLS) playlists, DRM-protected "
                + "and login-only videos are not supported. YouTube links: use the "
                + "Download button inside the app.",
            "Dán liên kết tới tệp video/âm thanh (mp4, mov, mp3, m4a…) hoặc trang "
                + "có nhúng chúng. Không hỗ trợ luồng HLS, video có DRM hoặc cần "
                + "đăng nhập. Liên kết YouTube: dùng nút Tải xuống trong app."
        )
        progressView.progressTintColor = theme.accent
        progressView.isHidden = true

        let paste = UIButton(type: .system)
        paste.setTitle(WebMediaText.text("Paste", "Dán"), for: .normal)
        paste.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [field, paste])
        row.spacing = 12
        let stack = UIStackView(arrangedSubviews: [
            row, startButton, progressView, audioButton, statusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 44),
            startButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            downloader?.cancel()
        }
    }

    private func configureField(_ theme: ThemeManager) {
        field.placeholder = "https://"
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.textColor = theme.primaryText
        field.backgroundColor = theme.surface
        field.layer.cornerRadius = 10
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        field.leftViewMode = .always
        field.delegate = self
    }

    private func configureButtons(_ theme: ThemeManager) {
        startButton.setTitle(
            WebMediaText.text("Download", "Tải xuống"), for: .normal
        )
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = theme.accent
        startButton.layer.cornerRadius = 10
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        audioButton.setTitle(
            WebMediaText.text("Save as audio (M4A)", "Lưu thành âm thanh (M4A)"),
            for: .normal
        )
        audioButton.isHidden = true
        audioButton.addTarget(self, action: #selector(audioTapped), for: .touchUpInside)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        startTapped()
        return true
    }

    @objc private func pasteTapped() {
        if let text = UIPasteboard.general.string {
            field.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func startTapped() {
        if let downloader {
            downloader.cancel()
            reset(message: WebMediaText.text("Cancelled", "Đã hủy"))
            return
        }
        view.endEditing(true)
        let job = WebMediaDownloader()
        downloader = job
        lastFile = nil
        audioButton.isHidden = true
        progressView.progress = 0
        progressView.isHidden = false
        statusLabel.text = WebMediaText.text("Downloading…", "Đang tải…")
        startButton.setTitle(WebMediaText.text("Cancel", "Hủy"), for: .normal)
        job.start(
            link: field.text ?? "",
            progress: { [weak self] value in
                self?.progressView.progress = Float(value)
            },
            completion: { [weak self] result in
                self?.finished(result)
            }
        )
    }

    private func finished(_ result: Result<URL, Error>) {
        switch result {
        case .success(let file):
            lastFile = file
            reset(message: WebMediaText.text("Saved: ", "Đã lưu: ") + file.lastPathComponent)
            let ext = file.pathExtension.lowercased()
            let isVideo = ["mp4", "m4v", "mov"].contains(ext)
            audioButton.isHidden = !isVideo
            share(file)
        case .failure(let error):
            AppLog.downloads("web download failed: \(error)")
            reset(message: error.localizedDescription)
        }
    }

    private func reset(message: String) {
        downloader = nil
        progressView.isHidden = true
        statusLabel.text = message
        startButton.setTitle(WebMediaText.text("Download", "Tải xuống"), for: .normal)
    }

    private func share(_ file: URL) {
        let activity = UIActivityViewController(
            activityItems: [file], applicationActivities: nil
        )
        VideoActionMenu.anchorPopover(activity, to: startButton)
        present(activity, animated: true)
    }

    @objc private func audioTapped() {
        guard let file = lastFile else {
            return
        }
        statusLabel.text = WebMediaText.text("Preparing audio…", "Đang chuẩn bị âm thanh…")
        let name = (file.lastPathComponent as NSString).deletingPathExtension
        AudioExporter.exportM4A(from: file, name: name) { [weak self] result in
            switch result {
            case .success(let audio):
                self?.statusLabel.text = audio.lastPathComponent
                self?.share(audio)
            case .failure(let error):
                self?.statusLabel.text = error.localizedDescription
            }
        }
    }
}
