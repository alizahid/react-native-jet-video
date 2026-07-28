import CryptoKit
import Foundation

/// Disk cache for progressive video sources. Each entry is a sparse data file
/// plus a metadata sidecar recording which byte ranges have been downloaded —
/// so partially streamed videos are cached too, and later playbacks only fetch
/// the missing ranges. LRU-evicted against `maxSizeBytes`.
final class VideoCache {
  static let shared = VideoCache()

  /// Total cache budget on disk. Read/written on `queue` only — use
  /// `configure(maxSizeBytes:)` from other threads.
  private var maxSizeBytes: Int64 = 1024 * 1024 * 1024

  func configure(maxSizeBytes: Int64) {
    queue.async { [self] in
      self.maxSizeBytes = maxSizeBytes
    }
    enforceLimit()
  }

  private let queue = DispatchQueue(label: "com.jetvideo.cache")
  private let directory: URL
  // Entries currently held by a resource loader; excluded from eviction.
  private let activeEntries = NSMapTable<NSString, CacheEntry>(
    keyOptions: .copyIn,
    valueOptions: .weakMemory
  )

  init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory = caches.appendingPathComponent("JetVideoCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func entry(for url: URL) -> CacheEntry {
    queue.sync {
      let key = Self.key(for: url)
      if let existing = activeEntries.object(forKey: key as NSString) {
        return existing
      }
      let entry = CacheEntry(
        url: url,
        dataURL: directory.appendingPathComponent("\(key).bin"),
        metaURL: directory.appendingPathComponent("\(key).json")
      )
      activeEntries.setObject(entry, forKey: key as NSString)
      return entry
    }
  }

  func clear(completion: @escaping () -> Void) {
    queue.async { [self] in
      // Reset in-use entries FIRST: close their file handles and wipe their
      // in-memory ranges. Otherwise an active entry keeps writing to an
      // orphaned (deleted) file while re-persisting metadata that claims
      // ranges the new on-disk file doesn't have — corrupting later playback.
      if let entries = activeEntries.objectEnumerator()?.allObjects as? [CacheEntry] {
        for entry in entries {
          entry.reset()
        }
      }
      let files = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
      for file in files {
        try? FileManager.default.removeItem(at: file)
      }
      DispatchQueue.main.async(execute: completion)
    }
  }

  func totalSize(completion: @escaping (Int64) -> Void) {
    queue.async { [self] in
      let size = diskSize()
      DispatchQueue.main.async { completion(size) }
    }
  }

  /// Evicts least-recently-used entries until the cache fits the budget.
  /// Called after downloads finish; entries in active use are skipped.
  func enforceLimit() {
    queue.async { [self] in
      guard diskSize() > maxSizeBytes else { return }
      let fileManager = FileManager.default
      let metas = ((try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey]
      )) ?? []).filter { $0.pathExtension == "json" }

      let sorted = metas.sorted { a, b in
        let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return dateA < dateB
      }

      var size = diskSize()
      for meta in sorted {
        guard size > maxSizeBytes else { break }
        let key = meta.deletingPathExtension().lastPathComponent
        guard activeEntries.object(forKey: key as NSString) == nil else { continue }
        let data = directory.appendingPathComponent("\(key).bin")
        let freed = Self.fileSize(data) + Self.fileSize(meta)
        try? fileManager.removeItem(at: data)
        try? fileManager.removeItem(at: meta)
        size -= freed
      }
    }
  }

  private func diskSize() -> Int64 {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
    )) ?? []
    return files.reduce(0) { $0 + Self.fileSize($1) }
  }

  // Allocated size, not logical size: cache files are sparse (ranges written
  // at offsets), so logical size would overcount unwritten holes.
  private static func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
    return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
  }

  static func key(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// One cached source: a sparse `.bin` data file plus `.json` metadata with the
/// downloaded ranges. Thread-safe; used from resource-loader queues.
final class CacheEntry {
  let url: URL

  private let dataURL: URL
  private let metaURL: URL
  private let lock = NSLock()

  private var readHandle: FileHandle?
  private var writeHandle: FileHandle?
  // Sorted, non-overlapping downloaded ranges.
  private var ranges: [Range<Int64>] = []
  private var storedContentLength: Int64?
  private var storedContentType: String?

  private struct Meta: Codable {
    var url: String
    var contentLength: Int64?
    var contentType: String?
    var ranges: [[Int64]]
  }

  init(url: URL, dataURL: URL, metaURL: URL) {
    self.url = url
    self.dataURL = dataURL
    self.metaURL = metaURL
    loadMeta()
  }

  deinit {
    try? readHandle?.close()
    try? writeHandle?.close()
  }

  var contentLength: Int64? {
    lock.lock()
    defer { lock.unlock() }
    return storedContentLength
  }

  var contentType: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedContentType
  }

  /// Forgets everything: closes file handles and wipes in-memory ranges so
  /// subsequent writes recreate the on-disk files from scratch. Called when
  /// the cache is cleared while this entry is in use.
  func reset() {
    lock.lock()
    defer { lock.unlock() }
    try? readHandle?.close()
    try? writeHandle?.close()
    readHandle = nil
    writeHandle = nil
    ranges = []
    storedContentLength = nil
    storedContentType = nil
  }

  func setContentInfo(length: Int64?, type: String?) {
    lock.lock()
    defer { lock.unlock() }
    if let length, storedContentLength != length {
      // A changed length means the remote file changed: drop stale ranges.
      if storedContentLength != nil {
        ranges = []
      }
      storedContentLength = length
    }
    if let type {
      storedContentType = type
    }
    persistMeta()
  }

  /// Returns cached bytes starting exactly at `offset` (up to `maxLength`,
  /// bounded by the contiguous cached range), or nil on a cache miss.
  func read(at offset: Int64, maxLength: Int) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard let range = ranges.first(where: { $0.contains(offset) }) else {
      return nil
    }
    let available = Int(min(Int64(maxLength), range.upperBound - offset))
    guard available > 0 else { return nil }
    if readHandle == nil {
      readHandle = try? FileHandle(forReadingFrom: dataURL)
    }
    guard let handle = readHandle else { return nil }
    do {
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: available)
      guard let data, !data.isEmpty else { return nil }
      return data
    } catch {
      return nil
    }
  }

  func write(_ data: Data, at offset: Int64) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    if writeHandle == nil {
      if !FileManager.default.fileExists(atPath: dataURL.path) {
        FileManager.default.createFile(atPath: dataURL.path, contents: nil)
      }
      writeHandle = try? FileHandle(forWritingTo: dataURL)
    }
    guard let handle = writeHandle else { return }
    do {
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: data)
      insertRange(offset..<offset + Int64(data.count))
      persistMeta()
    } catch {
      // Disk write failed (full disk, cleared cache): playback continues from
      // network; the range simply isn't recorded.
    }
  }

  private func insertRange(_ newRange: Range<Int64>) {
    var merged: [Range<Int64>] = []
    var pending = newRange
    for range in ranges {
      if range.upperBound < pending.lowerBound || range.lowerBound > pending.upperBound {
        merged.append(range)
      } else {
        pending = min(range.lowerBound, pending.lowerBound)..<max(range.upperBound, pending.upperBound)
      }
    }
    merged.append(pending)
    ranges = merged.sorted { $0.lowerBound < $1.lowerBound }
  }

  private func loadMeta() {
    guard let data = try? Data(contentsOf: metaURL),
          let meta = try? JSONDecoder().decode(Meta.self, from: data),
          meta.url == url.absoluteString,
          FileManager.default.fileExists(atPath: dataURL.path) else {
      return
    }
    storedContentLength = meta.contentLength
    storedContentType = meta.contentType
    // Sanity: a claimed range past the data file's logical size cannot be
    // backed by real bytes (sparse writes always extend the file to the
    // highest written offset) — drop such ranges instead of serving zeros.
    let fileSize = Int64(
      (try? FileManager.default.attributesOfItem(atPath: dataURL.path)[.size] as? Int64) ?? 0
    )
    ranges = meta.ranges.compactMap { pair in
      guard pair.count == 2, pair[0] < pair[1], pair[1] <= fileSize else { return nil }
      return pair[0]..<pair[1]
    }
  }

  // Callers hold `lock`.
  private func persistMeta() {
    let meta = Meta(
      url: url.absoluteString,
      contentLength: storedContentLength,
      contentType: storedContentType,
      ranges: ranges.map { [$0.lowerBound, $0.upperBound] }
    )
    if let data = try? JSONEncoder().encode(meta) {
      try? data.write(to: metaURL)
    }
  }
}
