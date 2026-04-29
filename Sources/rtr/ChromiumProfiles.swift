import Foundation

struct ChromiumProfile {
    let directory: String         // e.g. "Default", "Profile 1"
    let name: String              // user-facing display name
    let avatarFileName: String?   // raw `gaia_picture_file_name` from Local State, if any
    let avatarURL: URL?           // resolved path to the avatar PNG, if available on disk

    /// Used by `parse(localStateData:)` which doesn't know the support dir.
    init(directory: String, name: String, avatarFileName: String?, avatarURL: URL? = nil) {
        self.directory = directory
        self.name = name
        self.avatarFileName = avatarFileName
        self.avatarURL = avatarURL
    }
}

enum ChromiumProfiles {
    /// Reads `~/Library/Application Support/<subpath>/Local State` and returns profiles
    /// in the user's preferred order (`profile.profiles_order` if present), with
    /// avatar URLs resolved against the same support directory.
    static func load(supportSubpath: String) -> [ChromiumProfile] {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let supportRoot = support.appendingPathComponent(supportSubpath)
        let stateURL = supportRoot.appendingPathComponent("Local State")
        return load(stateURL: stateURL, supportRoot: supportRoot)
    }

    /// Test/DI seam: parse a `Local State` file at an arbitrary path. If
    /// `supportRoot` is non-nil, avatar URLs are resolved against it.
    static func load(stateURL: URL, supportRoot: URL? = nil) -> [ChromiumProfile] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        let parsed = parse(localStateData: data)
        guard let supportRoot else { return parsed }
        return parsed.map { p in
            guard let fileName = p.avatarFileName, !fileName.isEmpty else { return p }
            let url = supportRoot
                .appendingPathComponent(p.directory)
                .appendingPathComponent(fileName)
            // Only attach the URL if the file exists on disk — otherwise downstream
            // code thinks an avatar is available and renders a broken NSImage.
            guard FileManager.default.fileExists(atPath: url.path) else { return p }
            return ChromiumProfile(directory: p.directory,
                                   name: p.name,
                                   avatarFileName: p.avatarFileName,
                                   avatarURL: url)
        }
    }

    /// Pure parser — exposed for unit tests. Returns profiles with raw
    /// `avatarFileName` set, but `avatarURL` always nil (we don't know the
    /// filesystem layout from JSON alone).
    static func parse(localStateData data: Data) -> [ChromiumProfile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return []
        }

        var unordered: [(dir: String, name: String, avatar: String?)] = []
        for (dir, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            let name = (info["name"] as? String)
                ?? (info["shortcut_name"] as? String)
                ?? dir
            let avatar = info["gaia_picture_file_name"] as? String
            unordered.append((dir, name, avatar))
        }

        if let order = profile["profiles_order"] as? [String] {
            let ordered = order.compactMap { dir -> ChromiumProfile? in
                guard let m = unordered.first(where: { $0.dir == dir }) else { return nil }
                return ChromiumProfile(directory: m.dir, name: m.name, avatarFileName: m.avatar)
            }
            let remaining = unordered
                .filter { entry in !order.contains(entry.dir) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ChromiumProfile(directory: $0.dir, name: $0.name, avatarFileName: $0.avatar) }
            return ordered + remaining
        }

        return unordered
            .sorted { lhs, rhs in
                if lhs.dir == "Default" { return true }
                if rhs.dir == "Default" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { ChromiumProfile(directory: $0.dir, name: $0.name, avatarFileName: $0.avatar) }
    }
}
