import Foundation

struct ModelRequirement: Identifiable {
    let id: String
    let fileName: String
    let displayName: String
    let purpose: String
    let minBytes: Int64
    let remoteURL: URL?

    static let all: [ModelRequirement] = [
        ModelRequirement(id: "qwen",
                         fileName: AppPaths.qwenFileName,
                         displayName: "Qwen3.5-4B · Q4_K_M",
                         purpose: "本地生成答案",
                         minBytes: 2_700_000_000,
                         remoteURL: URL(string: "https://www.modelscope.cn/api/v1/models/AtomicChat/Qwen3.5-4B-GGUF/repo?Revision=master&FilePath=qwen35-4b-Q4_K_M.gguf")),
        ModelRequirement(id: "bge",
                         fileName: AppPaths.bgeFileName,
                         displayName: "bge-small-zh-v1.5 · f16",
                         purpose: "中文向量编码 / RAG 检索",
                         minBytes: 47_000_000,
                         remoteURL: URL(string: "https://huggingface.co/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/bge-small-zh-v1.5-f16.gguf"))
    ]
}

struct ModelStatus: Identifiable {
    let requirement: ModelRequirement
    let exists: Bool
    let complete: Bool
    let size: Int64
    var id: String { requirement.id }
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var statuses: [ModelStatus] = []
    @Published private(set) var downloading: [String: Double] = [:]
    @Published var lastMessage: String = ""

    private var downloader: ModelDownloader?

    private init() { refresh() }

    func refresh() {
        statuses = ModelRequirement.all.map { req in
            let url = AppPaths.modelURL(req.fileName)
            let size = AppPaths.fileSize(url)
            return ModelStatus(requirement: req,
                               exists: size > 0,
                               complete: size >= req.minBytes,
                               size: size)
        }
    }

    var allReady: Bool { statuses.allSatisfy(\.complete) }

    func urlFor(_ fileName: String) -> URL? {
        AppPaths.resolvedModelURL(fileName)
    }

    /// 从「文件」App / Finder 文件共享选中的文件导入。
    func importFile(from source: URL, as fileName: String) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let dest = AppPaths.modelURL(fileName)
        try? FileManager.default.createDirectory(at: AppPaths.modelsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        lastMessage = "已导入 \(fileName)"
        refresh()
    }

    /// 从 URL 下载（支持 Range 断点续传；配合 scripts/serve_models.py 走局域网最快）。
    func download(from url: URL,
                  as fileName: String,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        let dest = AppPaths.modelURL(fileName)
        let d = ModelDownloader(destination: dest)
        downloader = d
        d.onProgress = { [weak self] value in
            DispatchQueue.main.async {
                self?.downloading[fileName] = value
                progress(value)
            }
        }
        d.onComplete = { [weak self] result in
            DispatchQueue.main.async {
                self?.downloading.removeValue(forKey: fileName)
                self?.downloader = nil
                switch result {
                case .success:
                    self?.lastMessage = "下载完成：\(fileName)"
                    self?.refresh()
                case .failure(let e):
                    self?.lastMessage = "下载失败：\(e.localizedDescription)"
                }
                completion(result)
            }
        }
        d.start(from: url)
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        downloading.removeAll()
        lastMessage = "已暂停下载（保留 .part，可继续）"
    }

    func deleteModel(_ fileName: String) {
        let url = AppPaths.modelURL(fileName)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
        refresh()
    }
}

// MARK: - 断点续传下载器

final class ModelDownloader: NSObject, URLSessionDataDelegate {
    private let destination: URL
    private var partial: URL { destination.appendingPathExtension("part") }
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var startOffset: Int64 = 0
    private var total: Int64 = 0
    private var written: Int64 = 0
    private var cancelledByUser = false
    private var finished = false

    var onProgress: ((Double) -> Void)?
    var onComplete: ((Result<Void, Error>) -> Void)?

    init(destination: URL) {
        self.destination = destination
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func start(from url: URL) {
        try? FileManager.default.createDirectory(at: AppPaths.modelsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        startOffset = AppPaths.fileSize(partial)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if startOffset > 0 {
            request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
        }
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        cancelledByUser = true
        task?.cancel()
        try? handle?.close()
        handle = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let resumed = status == 206 && startOffset > 0
        if !resumed {
            // 服务端不支持 Range，从头写
            startOffset = 0
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        try? handle?.close()
        handle = try? FileHandle(forWritingTo: partial)
        if resumed { try? handle?.seekToEnd() }
        total = startOffset + (response.expectedContentLength > 0 ? response.expectedContentLength : 0)
        written = startOffset
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            if total > 0 { onProgress?(min(0.999, Double(written) / Double(total))) }
        } catch {
            task?.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if cancelledByUser { return }
        if let error { finish(.failure(error)); return }
        let size = AppPaths.fileSize(partial)
        let minSize = ModelRequirement.all.first { $0.fileName == destination.lastPathComponent }?.minBytes ?? 1
        guard size >= minSize else {
            finish(.failure(WikiError.modelLoadFailed("下载不完整（\(size) 字节），请检查网络后重试")))
            return
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
            onProgress?(1.0)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        onComplete?(result)
        onComplete = nil
        session.finishTasksAndInvalidate()
    }
}
