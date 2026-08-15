import Foundation

/// A published GitHub release newer than the running build.
struct AppRelease: Equatable, Sendable {
    let version: String
    let url: URL
    let name: String?
}

/// Checks the app's GitHub releases for a newer version. Pure version-comparison
/// logic is separated from the network call so it's unit-testable; the network
/// path queries the public GitHub releases *list* (no auth — the repo is public)
/// and degrades gracefully when there are no releases or the machine is offline.
///
/// It queries the releases list rather than `/releases/latest` on purpose: this
/// app ships every build as a GitHub **pre-release**, and `/releases/latest`
/// returns only the newest non-prerelease (404 when there are none), which would
/// wrongly report "no releases." The list includes pre-releases.
enum UpdateService {
    static let repo = "nikhilkomakula/ticky-task"

    enum Outcome: Equatable, Sendable {
        case upToDate
        case updateAvailable(AppRelease)
        case noReleases
    }

    static func check(currentVersion: String,
                      session: URLSession = .shared) async throws -> Outcome {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // A 404 here means the repo is missing/renamed/private — a genuine error,
        // NOT "no releases" (an empty repo returns 200 with an empty array). Only a
        // successfully decoded but empty/all-draft list maps to .noReleases below,
        // so a network/auth failure surfaces as an error instead of a false
        // "nothing published yet."
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct GHRelease: Decodable {
            let tag_name: String
            let html_url: String
            let name: String?
            let draft: Bool?
            let prerelease: Bool?
        }
        let decoded = try JSONDecoder().decode([GHRelease].self, from: data)
        let releases = decoded.map {
            ReleaseInfo(tag: $0.tag_name, urlString: $0.html_url, name: $0.name, isDraft: $0.draft ?? false)
        }

        guard let newest = newestRelease(from: releases) else { return .noReleases }
        guard isNewer(newest.tag, than: currentVersion),
              let releaseURL = URL(string: newest.urlString) else {
            return .upToDate
        }
        return .updateAvailable(AppRelease(version: normalize(newest.tag),
                                           url: releaseURL,
                                           name: newest.name))
    }

    /// A GitHub release reduced to what the updater needs — `Sendable` so it can
    /// cross the async boundary and be unit-tested without the network.
    struct ReleaseInfo: Equatable, Sendable {
        let tag: String
        let urlString: String
        let name: String?
        let isDraft: Bool
    }

    /// The newest non-draft release by version precedence. Pre-releases are
    /// **included** (this app ships every build as a GitHub pre-release), and the
    /// winner is chosen by SemVer precedence rather than GitHub's list ordering,
    /// so a late patch to an older line can't shadow the true newest.
    static func newestRelease(from releases: [ReleaseInfo]) -> ReleaseInfo? {
        releases
            .filter { !$0.isDraft }
            .max { compare(normalize($0.tag), normalize($1.tag)) == .orderedAscending }
    }

    // MARK: Version comparison (pure)

    /// Strip a leading "v" (e.g. "v3.1.0" → "3.1.0").
    static func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// True when `latest` is a strictly newer version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        compare(normalize(latest), normalize(current)) == .orderedDescending
    }

    /// Numeric dotted-component comparison of the release core (so 3.0.10 >
    /// 3.0.9, unlike a string compare), with SemVer prerelease semantics: a
    /// prerelease (e.g. `1.0.0-beta.1`) is OLDER than its matching stable
    /// release (`1.0.0`), so a `-beta` tag is never advertised to stable users.
    /// Missing numeric components count as 0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (coreA, preA) = splitPrerelease(a)
        let (coreB, preB) = splitPrerelease(b)

        let pa = components(coreA), pb = components(coreB)
        for index in 0..<max(pa.count, pb.count) {
            let x = index < pa.count ? pa[index] : 0
            let y = index < pb.count ? pb[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }

        // Equal cores: presence of a prerelease identifier lowers precedence.
        switch (preA.isEmpty, preB.isEmpty) {
        case (true, true):   return .orderedSame
        case (true, false):  return .orderedDescending   // a is stable, b is prerelease → a > b
        case (false, true):  return .orderedAscending     // a is prerelease → a < b
        case (false, false):
            if preA == preB { return .orderedSame }
            return preA < preB ? .orderedAscending : .orderedDescending
        }
    }

    /// Split "1.2.3-beta.1" into ("1.2.3", "beta.1"); no dash → ("1.2.3", "").
    private static func splitPrerelease(_ version: String) -> (core: String, prerelease: String) {
        guard let dash = version.firstIndex(of: "-") else { return (version, "") }
        return (String(version[..<dash]), String(version[version.index(after: dash)...]))
    }

    private static func components(_ core: String) -> [Int] {
        core.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
