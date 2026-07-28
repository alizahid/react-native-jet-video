import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Routes a progressive source's byte-range requests through the disk cache:
/// cached ranges are served from disk, gaps are fetched over the network and
/// written through to the cache as they stream in. AVPlayer talks to this via
/// a custom URL scheme so it never hits the network directly.
final class CachingResourceLoader: NSObject {
  private static let schemePrefix = "jvcache-"
  // Extensions safe for transparent range caching. HLS/DASH manifests must NOT
  // go through the loader (their segment URLs would break) and are excluded.
  private static let cacheableExtensions: Set<String> = [
    "mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav",
  ]

  let queue = DispatchQueue(label: "com.jetvideo.resourceloader")

  private let originalURL: URL
  private let headers: [String: String]
  private let entry: CacheEntry
  private let operationQueue: OperationQueue
  private var handlers: [AVAssetResourceLoadingRequest: RequestHandler] = [:]
  private var taskRouter: [Int: RequestHandler] = [:]
  // Created on first network miss (cache-served sources never need one).
  // NSURLSession retains its delegate until invalidated, so lifecycle is
  // managed by an explicit invalidate() — NOT deinit: with a live session
  // deinit can never run, and creating the lazy session during deinit hands
  // CFNetwork a half-deallocated delegate (use-after-free).
  private var session: URLSession?
  // Guarded by `queue`. A loading request that AVFoundation delivers after
  // invalidation must not recreate the session — it would never be
  // invalidated again, retaining this loader (and its download) forever.
  private var invalidated = false

  init(originalURL: URL, headers: [String: String]) {
    self.originalURL = originalURL
    self.headers = headers
    entry = VideoCache.shared.entry(for: originalURL)
    operationQueue = OperationQueue()
    operationQueue.maxConcurrentOperationCount = 1
    operationQueue.underlyingQueue = queue
    super.init()
  }

  deinit {
    VideoCache.shared.enforceLimit()
  }

  /// Cancels all in-flight work and breaks the session→delegate retain so the
  /// loader can deallocate. Must be called when the owning item is detached;
  /// safe to call multiple times and from any thread.
  func invalidate() {
    queue.async { [self] in
      invalidated = true
      for handler in handlers.values {
        handler.cancel()
      }
      handlers.removeAll()
      taskRouter.removeAll()
      session?.invalidateAndCancel()
      session = nil
    }
  }

  private func networkSession() -> URLSession {
    if let session {
      return session
    }
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: operationQueue)
    self.session = session
    return session
  }

  /// The custom-scheme URL AVPlayer should load, or nil when this source
  /// should bypass the cache (HLS, local files, unknown formats).
  static func assetURL(for url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }
    guard cacheableExtensions.contains(url.pathExtension.lowercased()) else {
      return nil
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = schemePrefix + scheme
    return components?.url
  }

  static func originalURL(from assetURL: URL) -> URL? {
    guard let scheme = assetURL.scheme, scheme.hasPrefix(schemePrefix) else {
      return nil
    }
    var components = URLComponents(url: assetURL, resolvingAgainstBaseURL: false)
    components?.scheme = String(scheme.dropFirst(schemePrefix.count))
    return components?.url
  }

  // MARK: - Request handling (all on `queue`)

  fileprivate func startHandler(for loadingRequest: AVAssetResourceLoadingRequest) {
    guard !invalidated else {
      loadingRequest.finishLoading(with: NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled
      ))
      return
    }
    let handler = RequestHandler(
      loadingRequest: loadingRequest,
      entry: entry,
      originalURL: originalURL,
      headers: headers,
      makeTask: { [weak self] request, handler in
        guard let self, !invalidated else { return nil }
        let task = networkSession().dataTask(with: request)
        taskRouter[task.taskIdentifier] = handler
        return task
      },
      onFinished: { [weak self] handler in
        self?.removeHandler(handler)
      }
    )
    handlers[loadingRequest] = handler
    handler.start()
  }

  fileprivate func cancelHandler(for loadingRequest: AVAssetResourceLoadingRequest) {
    handlers[loadingRequest]?.cancel()
    handlers[loadingRequest] = nil
  }

  private func removeHandler(_ handler: RequestHandler) {
    if let task = handler.task {
      taskRouter[task.taskIdentifier] = nil
    }
    handlers = handlers.filter { $0.value !== handler }
  }
}

// MARK: - AVAssetResourceLoaderDelegate

extension CachingResourceLoader: AVAssetResourceLoaderDelegate {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    startHandler(for: loadingRequest)
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    cancelHandler(for: loadingRequest)
  }
}

// MARK: - URLSessionDataDelegate

extension CachingResourceLoader: URLSessionDataDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    taskRouter[dataTask.taskIdentifier]?.didReceive(response: response)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    taskRouter[dataTask.taskIdentifier]?.didReceive(data: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    taskRouter[task.taskIdentifier]?.didComplete(error: error)
    taskRouter[task.taskIdentifier] = nil
  }
}

/// Serves one AVAssetResourceLoadingRequest: drains the cache from the
/// requested offset, then streams the remaining gap from the network (writing
/// through to the cache). Runs entirely on the loader's serial queue.
private final class RequestHandler {
  let loadingRequest: AVAssetResourceLoadingRequest
  private(set) var task: URLSessionDataTask?

  private let entry: CacheEntry
  private let originalURL: URL
  private let headers: [String: String]
  private let makeTask: (URLRequest, RequestHandler) -> URLSessionDataTask?
  private let onFinished: (RequestHandler) -> Void

  private var currentOffset: Int64 = 0
  // Exclusive upper bound of the requested window; nil = to end of resource.
  private var endOffset: Int64?
  // Where the next incoming network byte lands in the resource.
  private var networkOffset: Int64 = 0
  private var finished = false

  private static let readChunk = 512 * 1024

  init(
    loadingRequest: AVAssetResourceLoadingRequest,
    entry: CacheEntry,
    originalURL: URL,
    headers: [String: String],
    makeTask: @escaping (URLRequest, RequestHandler) -> URLSessionDataTask?,
    onFinished: @escaping (RequestHandler) -> Void
  ) {
    self.loadingRequest = loadingRequest
    self.entry = entry
    self.originalURL = originalURL
    self.headers = headers
    self.makeTask = makeTask
    self.onFinished = onFinished
  }

  func start() {
    if let dataRequest = loadingRequest.dataRequest {
      currentOffset = dataRequest.requestedOffset
      if !dataRequest.requestsAllDataToEndOfResource {
        endOffset = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
      }
    }

    fillContentInfoFromCache()

    // A pure content-info request (no data) that the cache can answer.
    if loadingRequest.dataRequest == nil {
      if loadingRequest.contentInformationRequest?.contentLength ?? 0 > 0 {
        finish(error: nil)
      } else {
        startNetwork(from: 0)
      }
      return
    }

    serveFromCache()
  }

  func cancel() {
    finished = true
    task?.cancel()
  }

  // MARK: - Cache path

  private func serveFromCache() {
    guard !finished, let dataRequest = loadingRequest.dataRequest else { return }
    while !finished {
      if let end = endOffset, currentOffset >= end {
        finish(error: nil)
        return
      }
      let maxLength = remainingLength()
      guard maxLength > 0 else {
        finish(error: nil)
        return
      }
      guard let data = entry.read(at: currentOffset, maxLength: maxLength) else {
        startNetwork(from: currentOffset)
        return
      }
      dataRequest.respond(with: data)
      currentOffset += Int64(data.count)
      if contentInfoIncomplete() {
        fillContentInfoFromCache()
      }
    }
  }

  private func remainingLength() -> Int {
    if let end = endOffset {
      return Int(min(Int64(Self.readChunk), end - currentOffset))
    }
    if let total = entry.contentLength {
      return Int(min(Int64(Self.readChunk), max(0, total - currentOffset)))
    }
    return Self.readChunk
  }

  // MARK: - Network path

  private func startNetwork(from offset: Int64) {
    guard !finished, task == nil else { return }
    var request = URLRequest(url: originalURL)
    for (field, value) in headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
    // Transparent gzip/br decoding would desync our byte offsets from the
    // server's Content-Range and silently corrupt the cache.
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let end = endOffset {
      request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
    } else {
      request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
    }
    networkOffset = offset
    guard let task = makeTask(request, self) else { return }
    self.task = task
    task.resume()
  }

  func didReceive(response: URLResponse) {
    guard !finished, let http = response as? HTTPURLResponse else { return }
    if http.statusCode == 200 {
      // Server ignored the Range header and is sending the whole file from 0.
      networkOffset = 0
      entry.setContentInfo(
        length: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
        type: response.mimeType
      )
    } else if http.statusCode == 206 {
      let contentRange = http.value(forHTTPHeaderField: "Content-Range")
      var total = contentRange?.split(separator: "/").last.flatMap { Int64($0) }
      if total == nil, response.expectedContentLength > 0 {
        // "Content-Range: bytes x-y/*" — derive the total from this window.
        total = networkOffset + response.expectedContentLength
      }
      entry.setContentInfo(length: total, type: response.mimeType)
    } else {
      finish(error: NSError(
        domain: "com.jetvideo.cache",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) while loading video"]
      ))
      return
    }
    fillContentInfoFromCache()
    // A content-info-only request is satisfied by the headers alone — finish
    // now instead of streaming the whole file before AVPlayer can proceed.
    if loadingRequest.dataRequest == nil, !contentInfoIncomplete() {
      finish(error: nil)
      task?.cancel()
    }
  }

  func didReceive(data: Data) {
    guard !finished else { return }
    entry.write(data, at: networkOffset)
    let chunkEnd = networkOffset + Int64(data.count)
    if let dataRequest = loadingRequest.dataRequest, chunkEnd > currentOffset, currentOffset >= networkOffset {
      let skip = Int(currentOffset - networkOffset)
      var usable = skip > 0 ? data.subdata(in: skip..<data.count) : data
      if let end = endOffset {
        let allowed = Int(end - currentOffset)
        if usable.count > allowed {
          usable = usable.subdata(in: 0..<allowed)
        }
      }
      if !usable.isEmpty {
        dataRequest.respond(with: usable)
        currentOffset += Int64(usable.count)
      }
    }
    networkOffset = chunkEnd
    if let end = endOffset, currentOffset >= end {
      finish(error: nil)
      task?.cancel()
    }
  }

  func didComplete(error: Error?) {
    guard !finished else { return }
    task = nil
    if let error {
      if (error as NSError).code == NSURLErrorCancelled {
        return
      }
      finish(error: error)
      return
    }
    // The network stream ended: either the window is done, or the tail of the
    // requested window is now in cache (a competing handler fetched it).
    if loadingRequest.dataRequest != nil,
       let end = endOffset, currentOffset < end,
       entry.read(at: currentOffset, maxLength: 1) != nil {
      serveFromCache()
      return
    }
    finish(error: nil)
  }

  // MARK: - Content info

  private func contentInfoIncomplete() -> Bool {
    guard let info = loadingRequest.contentInformationRequest else { return false }
    return info.contentLength <= 0
  }

  private func fillContentInfoFromCache() {
    guard let info = loadingRequest.contentInformationRequest else { return }
    if let length = entry.contentLength {
      info.contentLength = length
    }
    if info.contentType == nil {
      // Prefer the server's MIME; else derive from the URL extension (the
      // loader only accepts whitelisted extensions, so this is reliable).
      // Hardcoding MP4 here mislabels audio sources (.mp3/.wav) and can make
      // AVFoundation fail to parse them.
      let mime = entry.contentType
      let type = mime.flatMap { UTType(mimeType: $0)?.identifier }
        ?? UTType(filenameExtension: originalURL.pathExtension)?.identifier
      info.contentType = type ?? UTType.mpeg4Movie.identifier
    }
    info.isByteRangeAccessSupported = true
  }

  private func finish(error: Error?) {
    guard !finished else { return }
    finished = true
    if let error {
      loadingRequest.finishLoading(with: error)
    } else {
      loadingRequest.finishLoading()
    }
    onFinished(self)
  }
}
