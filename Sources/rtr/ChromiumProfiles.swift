import Foundation

struct ChromiumProfile {
    let directory: String   // e.g. "Default", "Profile 1"
    let name: String        // user-facing display name
}

enum ChromiumProfiles {
    /// Reads `~/Library/Application Support/<subpath>/Local State` and returns profiles
    /// in the user's preferred order (profile.profiles_order if present).
    static func load(supportSubpath: String) -> [ChromiumProfile] {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let stateURL = support.appendingPathComponent(supportSubpath).appendingPathComponent("Local State")
        return load(stateURL: stateURL)
    }

    /// Test/DI seam: parse a `Local State` file at an arbitrary path.
    static func load(stateURL: URL) -> [ChromiumProfile] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        return parse(localStateData: data)
    }

    /// Pure parser — exposed for unit tests.
    static func parse(localStateData data: Data) -> [ChromiumProfile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return []
        }

        var unordered: [(dir: String, name: String)] = []
        for (dir, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            let name = (info["name"] as? String)
                ?? (info["shortcut_name"] as? String)
                ?? dir
            unordered.append((dir, name))
        }

        if let order = profile["profiles_order"] as? [String] {
            let ordered = order.compactMap { dir -> ChromiumProfile? in
                guard let match = unordered.first(where: { $0.dir == dir }) else { return nil }
                return ChromiumProfile(directory: match.dir, name: match.name)
            }
            let remaining = unordered
                .filter { entry in !order.contains(entry.dir) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ChromiumProfile(directory: $0.dir, name: $0.name) }
            return ordered + remaining
        }

        return unordered
            .sorted { lhs, rhs in
                if lhs.dir == "Default" { return true }
                if rhs.dir == "Default" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { ChromiumProfile(directory: $0.dir, name: $0.name) }
    }
}
