import Foundation

/// A release of the app that is newer than the one running.
public struct AppUpdate: Codable, Sendable, Equatable {
    public var version: String
    public var page: String  // the release's page, with what is new
    public var download: String?  // the disk image, when the release has one

    public init(version: String, page: String, download: String? = nil) {
        self.version = version
        self.page = page
        self.download = download
    }
}

/// What the app remembers between launches: when it last asked, and the newest release it heard of.
public struct UpdateMemory: Codable, Sendable, Equatable {
    public var checkedAt: Double
    public var latest: AppUpdate?

    public init(checkedAt: Double, latest: AppUpdate?) {
        self.checkedAt = checkedAt
        self.latest = latest
    }
}

/// Asking GitHub whether a newer version of the app has been released. One anonymous request, at
/// most once a day; nothing about the Mac, the folders or the photos is sent.
public enum UpdateCheck {
    public static let latestRelease = URL(string: "https://api.github.com/repos/Krutik460/photo-cleanup/releases/latest")!
    public static let interval = 24.0 * 3600

    /// "v0.10.1" as [0, 10, 1]. What follows the numbers ("-beta") is left out.
    static func numbers(_ version: String) -> [Int] {
        let core = version.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Whether version `a` is newer than `b`: "0.10" is newer than "0.9", "1.0" is "1.0.0".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        guard !x.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The release in GitHub's reply. Nil for a draft, a prerelease, or a reply that is not one.
    /// Links are taken only when they are https links to github.com: they get opened in the browser.
    public static func release(from data: Data) -> AppUpdate? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String, !numbers(tag).isEmpty,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(trusted) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.lowercased().hasSuffix(".dmg") }.flatMap(trusted)
        return AppUpdate(version: numbers(tag).map(String.init).joined(separator: "."), page: page, download: dmg)
    }

    static func trusted(_ link: String) -> String? {
        guard let url = URL(string: link), url.scheme == "https", url.host == "github.com" else { return nil }
        return link
    }

    public static func isDue(_ memory: UpdateMemory?, now: Double) -> Bool {
        guard let memory else { return true }
        return now - memory.checkedAt >= interval || now < memory.checkedAt
    }

    /// What is remembered, when it is news to the running version.
    public static func available(_ memory: UpdateMemory?, current: String) -> AppUpdate? {
        guard let latest = memory?.latest, isNewer(latest.version, than: current) else { return nil }
        return latest
    }

    public static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PhotoCleanup", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Core ML keeps a compiled copy of a model in the app's caches for every place the model was loaded
/// from (the app in Downloads, on a disk image, in Applications, an earlier version's model) and
/// never removes one. When the cache holds clearly more than the one copy in use, it is emptied;
/// Core ML makes the copy it needs again when the model is loaded, in a fraction of a second.
/// Call it before loading the model. Returns the bytes it freed.
@discardableResult
public func trimCompiledModelCache(in caches: URL, model: URL) -> Int {
    let cache = caches.appendingPathComponent("com.apple.e5rt.e5bundlecache")
    let held = directorySize(cache), one = directorySize(model)
    guard one > 0, held > one * 3 / 2 else { return 0 }
    try? FileManager.default.removeItem(at: cache)
    return held
}

func directorySize(_ dir: URL) -> Int {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total = 0
    for case let url as URL in e {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += v?.fileSize ?? 0 }
    }
    return total
}
