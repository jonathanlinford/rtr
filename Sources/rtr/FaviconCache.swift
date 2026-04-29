import AppKit

/// Fetches favicons for a URL's host, with in-memory + on-disk caching keyed by host.
/// Uses DuckDuckGo's icon service; silently falls back to nil when unreachable.
final class FaviconCache {
    static let shared = FaviconCache()

    private let memory = NSCache<NSString, NSImage>()
    private let diskDir: URL
    private let queue = DispatchQueue(label: "rtr.favicon", qos: .userInitiated)
    private let inflightLock = NSLock()
    private var inflight: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = caches.appendingPathComponent("com.jonny.rtr/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Returns a cached favicon synchronously if available in memory, for immediate display.
    func cachedImage(for url: URL) -> NSImage? {
        guard let host = url.host else { return nil }
        return memory.object(forKey: host as NSString)
    }

    /// Resolves the favicon for `url`, invoking `completion` on the main queue.
    /// Reads memory → disk → network in order; memoizes on all hits.
    func favicon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        guard let host = url.host, !host.isEmpty else {
            completion(nil); return
        }
        if let hit = memory.object(forKey: host as NSString) {
            completion(hit); return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if let fromDisk = self.readDisk(host: host) {
                self.memory.setObject(fromDisk, forKey: host as NSString)
                DispatchQueue.main.async { completion(fromDisk) }
                return
            }

            // Coalesce concurrent fetches for the same host.
            self.inflightLock.lock()
            if self.inflight[host] != nil {
                self.inflight[host]?.append(completion)
                self.inflightLock.unlock()
                return
            }
            self.inflight[host] = [completion]
            self.inflightLock.unlock()

            self.fetch(host: host) { image in
                if let image {
                    self.memory.setObject(image, forKey: host as NSString)
                    self.writeDisk(host: host, image: image)
                }
                self.inflightLock.lock()
                let waiters = self.inflight[host] ?? []
                self.inflight[host] = nil
                self.inflightLock.unlock()
                DispatchQueue.main.async {
                    for cb in waiters { cb(image) }
                }
            }
        }
    }

    private func fetch(host: String, completion: @escaping (NSImage?) -> Void) {
        // Google's s2 endpoint returns clean 32px PNGs; DuckDuckGo is the fallback.
        let endpoints = [
            "https://www.google.com/s2/favicons?sz=64&domain=\(host)",
            "https://icons.duckduckgo.com/ip3/\(host).ico"
        ]
        fetchChain(endpoints: endpoints, index: 0, completion: completion)
    }

    private func fetchChain(endpoints: [String], index: Int, completion: @escaping (NSImage?) -> Void) {
        guard index < endpoints.count, let url = URL(string: endpoints[index]) else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("rtr/0.1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            if let data, !data.isEmpty, http?.statusCode == 200,
               let image = NSImage(data: data), image.isValid,
               image.size.width > 1, image.size.height > 1 {
                completion(image)
                return
            }
            self?.fetchChain(endpoints: endpoints, index: index + 1, completion: completion)
        }.resume()
    }

    private func diskURL(host: String) -> URL {
        // Host is already a legal filename (no slashes allowed in DNS hostnames),
        // but lowercase-normalize to avoid duplicate cache entries.
        return diskDir.appendingPathComponent("\(host.lowercased()).png")
    }

    private func readDisk(host: String) -> NSImage? {
        let path = diskURL(host: host)
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private func writeDisk(host: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: diskURL(host: host), options: .atomic)
    }
}
