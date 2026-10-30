import Foundation

struct Release: Equatable {
    let version: String
    let page: URL
}

/// Asks GitHub for the latest published release. Sends no data beyond the request itself.
enum UpdateChecker {
    static let latestURL = URL(string: "https://api.github.com/repos/tinykings/Throat/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/tinykings/Throat/releases/latest")!
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Calls back on the main queue with the latest release, or nil if the check failed.
    static func latest(completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap(parse) : nil
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    static func parse(_ data: Data) -> Release? {
        struct Payload: Decodable { let tag_name: String; let html_url: URL? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, page: payload.html_url ?? releasesPage)
    }

    /// Compares dotted versions numerically, so 0.10.0 is newer than 0.9.0 and 1.0 equals 1.0.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (version: String) in version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
