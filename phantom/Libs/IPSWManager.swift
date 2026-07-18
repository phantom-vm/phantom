import Foundation
import Virtualization

@MainActor
@Observable
class IPSWManager {

    // MARK: - State

    enum State: Equatable {
        case none
        case fetching
        case downloading(progress: Double)
        case downloaded(path: URL)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.fetching, .fetching): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.downloaded(let a), .downloaded(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .none
    private(set) var info: String = ""

    // MARK: - Private

    private let ipswsDir: URL

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?

    private let log: (String) -> Void

    init(ipswsDir: URL, log: @escaping (String) -> Void) {
        self.ipswsDir = ipswsDir
        self.log = log
        try? FileManager.default.createDirectory(at: ipswsDir, withIntermediateDirectories: true)
    }

    func loadExisting() {
        checkExisting()
    }

    // MARK: - Public API

    /// Returns the downloaded IPSW path, or nil if not downloaded
    var downloadedPath: URL? {
        if case .downloaded(let path) = state { return path }
        return nil
    }

    func download() async {
        guard state == .none || {
            if case .error = state { return true }
            return false
        }() else { return }

        log("Fetching latest macOS restore IPSW info...")
        state = .fetching

        do {
            let restoreImage = try await VZMacOSRestoreImage.latestSupported
            let buildVersion = restoreImage.buildVersion
            let url = restoreImage.url

            log("Found: macOS build \(buildVersion)")
            log("Download URL: \(url)")
            info = "macOS build \(buildVersion)"

            let destination = ipswsDir.appendingPathComponent("\(buildVersion).ipsw")

            if FileManager.default.fileExists(atPath: destination.path) {
                log("IPSW already downloaded at \(destination.path)")
                state = .downloaded(path: destination)
                return
            }

            log("Starting download...")
            startDownload(from: url, to: destination)
        } catch {
            log("Failed to fetch IPSW info: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    /// Download a specific IPSW by direct URL (catalog-driven; the caller is
    /// responsible for validating the URL against Apple's CDN)
    func download(url: URL, build: String) async {
        switch state {
        case .fetching, .downloading:
            log("A download is already in progress")
            return
        default:
            break
        }

        let destination = ipswsDir.appendingPathComponent("\(build).ipsw")
        info = build

        if FileManager.default.fileExists(atPath: destination.path) {
            log("IPSW \(build) already downloaded")
            state = .downloaded(path: destination)
            return
        }

        log("Starting download of \(build) from \(url.host ?? "?")...")
        startDownload(from: url, to: destination)
    }

    private func startDownload(from url: URL, to destination: URL) {
        state = .downloading(progress: 0)

        let delegate = DownloadDelegate(
            destination: destination,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress)
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let path):
                        self.log("IPSW saved to \(path.path)")
                        self.state = .downloaded(path: path)
                    case .failure(let error):
                        self.log("Download failed: \(error.localizedDescription)")
                        self.state = .error(error.localizedDescription)
                    }
                }
            }
        )
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    func list() -> [IPSWInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: ipswsDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return []
        }

        return files.filter { $0.pathExtension == "ipsw" }.compactMap { url in
            guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = resourceValues.fileSize else {
                return nil
            }
            return IPSWInfo(
                id: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                size: size
            )
        }
    }

    // MARK: - Private

    private func checkExisting() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ipswsDir, includingPropertiesForKeys: nil),
              let ipsw = files.first(where: { $0.pathExtension == "ipsw" }) else { return }
        state = .downloaded(path: ipsw)
        info = ipsw.deletingPathExtension().lastPathComponent
        log("Found existing IPSW: \(ipsw.lastPathComponent)")
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void

    init(destination: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(.success(destination))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }
}
