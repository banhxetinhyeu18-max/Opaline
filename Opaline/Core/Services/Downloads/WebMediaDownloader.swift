// swiftlint:disable all
import Foundation

/// Two-language text for the web-download screens. Kept local so the feature
/// is one self-contained patch with no edits to the Localizable files.
enum WebMediaText {
    static func text(_ english: String, _ vietnamese: String) -> String {
        AppLanguage.effective.rawValue == "vi" ? vietnamese : english
    }
}

enum WebMediaError: LocalizedError {
    case invalidURL
    case useMainApp
    case noMedia
    case streamOnly
    case http(Int)
    case storage

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return WebMediaText.text(
                "Enter a valid http(s) link",
                "Hãy nhập liên kết http(s) hợp lệ"
            )
        case .useMainApp:
            return WebMediaText.text(
                "YouTube links: use the Download button inside the app",
                "Liên kết YouTube: hãy dùng nút Tải xuống trong app"
            )
        case .noMedia:
            return WebMediaText.text(
                "No downloadable video or audio found on this page",
                "Không tìm thấy video hoặc âm thanh tải được trên trang này"
            )
        case .streamOnly:
            return WebMediaText.text(
                "This page only offers a streaming (HLS) video, which isn't supported",
                "Trang này chỉ có luồng phát (HLS), chưa được hỗ trợ"
            )
        case .http(let code):
            return WebMediaText.text(
                "The server answered with error \(code)",
                "Máy chủ trả về lỗi \(code)"
            )
        case .storage:
            return WebMediaText.text(
                "Couldn't save the file", "Không lưu được tệp"
            )
        }
    }
}

/// Saves a video or audio file from any web address: a direct link to a
/// media file, or a normal page that embeds one (`og:video`, `<video>`,
/// `<source>` or a bare media URL in the page).
///
/// Not a site-specific extractor: pages that hide the file behind scripts,
/// DRM or a streaming playlist (HLS/DASH) will report "nothing found".
/// Every callback arrives on the main thread.
final class WebMediaDownloader: NSObject {
    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"
    ]
    private static let blockedHosts = [
        "youtube.com", "youtu.be", "youtube-nocookie.com"
    ]
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    static var folder: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let url = base.appendingPathComponent("WebDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var fetcher: WebPageFetcher?
    private var candidates: [URL] = []
    private var referer: URL?
    private var saved: URL?
    private var lastFailure: Error?
    private var isCancelled = false
    private var progress: ((Double) -> Void)?
    private var completion: ((Result<URL, Error>) -> Void)?

    // MARK: - Public API

    func start(
        link: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.progress = progress
        self.completion = completion
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            finish(.failure(WebMediaError.invalidURL))
            return
        }
        if Self.blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            finish(.failure(WebMediaError.useMainApp))
            return
        }
        if Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
            candidates = [url]
            next()
            return
        }
        let page = WebPageFetcher(url: url)
        fetcher = page
        page.run { [weak self] outcome in
            self?.handle(outcome, pageURL: url)
        }
    }

    func cancel() {
        isCancelled = true
        fetcher?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        completion = nil
    }

    // MARK: - Page → candidates

    private func handle(_ outcome: WebPageFetcher.Outcome, pageURL: URL) {
        switch outcome {
        case .failure(let error):
            finish(.failure(error))
        case .media(let url):
            candidates = [url]
            next()
        case let .page(html, finalURL):
            referer = finalURL
            let links = Self.mediaLinks(in: html, base: finalURL)
            let playable = links.filter { !Self.isPlaylist($0) }
            if playable.isEmpty {
                finish(.failure(
                    links.isEmpty ? WebMediaError.noMedia : WebMediaError.streamOnly
                ))
                return
            }
            candidates = playable
            next()
        }
    }

    // MARK: - Transfer

    private func next() {
        guard !isCancelled else {
            return
        }
        guard !candidates.isEmpty else {
            finish(.failure(lastFailure ?? WebMediaError.noMedia))
            return
        }
        let url = candidates.removeFirst()
        session?.invalidateAndCancel()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let newSession = URLSession(
            configuration: config, delegate: self, delegateQueue: .main
        )
        session = newSession
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let job = newSession.downloadTask(with: request)
        task = job
        job.resume()
    }

    private func finish(_ result: Result<URL, Error>) {
        let callback = completion
        completion = nil
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { callback?(result) }
}

// MARK: - Helpers

extension WebMediaDownloader {
    private static func isPlaylist(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "mpd"
    }

    /// Ordered by how reliable the source is: social-card meta tags, then
    /// media elements, then any media URL that appears in the text.
    static func mediaLinks(in raw: String, base: URL) -> [URL] {
        let html = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
        let quoted = "[\"']([^\"']+)[\"']"
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"'](?:og:video(?::secure_url|:url)?"
                + "|og:audio|twitter:player:stream)[\"'][^>]+content=" + quoted,
            "<meta[^>]+content=" + quoted + "[^>]+(?:property|name)=[\"']"
                + "(?:og:video(?::secure_url|:url)?|og:audio|twitter:player:stream)[\"']",
            "<(?:video|audio|source)[^>]+src=" + quoted,
            "(https?://[^\"'\\s<>\\\\]+?\\.(?:mp4|m4v|mov|webm|mp3|m4a|aac|m3u8)"
                + "(?:\\?[^\"'\\s<>\\\\]*)?)"
        ]
        var seen = Set<String>()
        var result: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, options: [], range: range)
                where match.numberOfRanges > 1 {
                guard let part = Range(match.range(at: 1), in: html),
                      let url = URL(string: String(html[part]), relativeTo: base)?
                          .absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      seen.insert(url.absoluteString).inserted else {
                    continue
                }
                result.append(url)
            }
        }
        return result
    }

    private static func fileExtension(forMime mime: String?) -> String {
        switch (mime ?? "").lowercased() {
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/ogg":
            return "ogg"
        case "video/webm":
            return "webm"
        case "video/quicktime":
            return "mov"
        default:
            return "mp4"
        }
    }

    // MARK: - Saving

    private func store(_ location: URL, response: HTTPURLResponse) throws -> URL {
        let manager = FileManager.default
        let name = fileName(for: response)
        let nameURL = URL(fileURLWithPath: name)
        var destination = Self.folder.appendingPathComponent(name)
        var index = 1
        while manager.fileExists(atPath: destination.path) {
            let base = nameURL.deletingPathExtension().lastPathComponent
            let ext = nameURL.pathExtension
            destination = Self.folder.appendingPathComponent(
                "\(base)-\(index)" + (ext.isEmpty ? "" : ".\(ext)")
            )
            index += 1
        }
        try manager.moveItem(at: location, to: destination)
        return destination
    }

    private func fileName(for response: HTTPURLResponse) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        var name = (response.suggestedFilename ?? "media")
            .components(separatedBy: banned)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            name = "media"
        }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += "." + Self.fileExtension(forMime: response.mimeType)
        }
        return String(name.suffix(100))
    }
}

// MARK: - URLSession delegate

extension WebMediaDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            lastFailure = WebMediaError.noMedia
            return
        }
        guard (200...299).contains(response.statusCode) else {
            lastFailure = WebMediaError.http(response.statusCode)
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") {
            lastFailure = WebMediaError.noMedia
            return
        }
        do {
            saved = try store(location, response: response)
        } catch {
            lastFailure = WebMediaError.storage
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !isCancelled, completion != nil else {
            return
        }
        if let saved {
            finish(.success(saved))
            return
        }
        if let error, lastFailure == nil {
            lastFailure = error
        }
        next()
    }
}


/// Reads the start of a page, and stops early when the address turns out to
/// be the media file itself.
final class WebPageFetcher: NSObject, URLSessionDataDelegate {
    enum Outcome {
        case page(html: String, url: URL)
        case media(URL)
        case failure(Error)
    }

    private static let limit = 3 * 1_048_576
    private let url: URL
    private var buffer = Data()
    private var session: URLSession?
    private var completion: ((Outcome) -> Void)?
    private var finalURL: URL

    init(url: URL) {
        self.url = url
        self.finalURL = url
    }

    func run(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let newSession = URLSession(
            configuration: config, delegate: self, delegateQueue: .main
        )
        session = newSession
        var request = URLRequest(url: url)
        request.setValue(
            WebMediaDownloader.userAgent, forHTTPHeaderField: "User-Agent"
        )
        newSession.dataTask(with: request).resume()
    }

    func cancel() {
        completion = nil
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        finalURL = response.url ?? url
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(WebMediaError.http(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        let isPlaylist = mime.contains("mpegurl") || mime.contains("dash+xml")
        if isPlaylist {
            finish(.failure(WebMediaError.streamOnly))
            completionHandler(.cancel)
        } else if mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime == "application/octet-stream" {
            finish(.media(finalURL))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        buffer.append(data)
        if buffer.count > Self.limit {
            finishPage()
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, buffer.isEmpty {
            finish(.failure(error))
        } else {
            finishPage()
        }
    }

    private func finishPage() {
        let html = String(data: buffer, encoding: .utf8)
            ?? String(data: buffer, encoding: .isoLatin1)
            ?? ""
        finish(.page(html: html, url: finalURL))
    }

    private func finish(_ outcome: Outcome) {
        let callback = completion
        completion = nil
        session?.invalidateAndCancel()
        callback?(outcome)
    }
}
