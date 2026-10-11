import Foundation

/// A semantic version like 1.2.3 or 1.3.0-beta.2 (a leading "v" is accepted).
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Pre-release identifiers ("beta", "2"); empty for a release.
    public var prerelease: [String]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let mainAndPre = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = mainAndPre.first, let coreText = head.split(separator: "+").first else { return nil }
        let core = coreText.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !core.isEmpty, core.count <= 3, core.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = core.map { $0! } + Array(repeating: 0, count: 3 - core.count)
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
        if mainAndPre.count > 1 {
            guard let pre = mainAndPre[1].split(separator: "+").first, !pre.isEmpty else { return nil }
            prerelease = pre.split(separator: ".").map(String.init)
        } else {
            prerelease = []
        }
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release ranks above its pre-releases (SemVer §11).
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    public static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
}

/// The part of GitHub's release JSON DockState reads.
public struct ReleaseInfo: Decodable, Sendable, Equatable {
    public var tagName: String
    public var htmlURL: URL
    public var draft: Bool
    public var prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }

    public init(tagName: String, htmlURL: URL, draft: Bool, prerelease: Bool) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
    }
}

public enum UpdateCheck {
    /// The newest published release that is newer than `current`, if any.
    /// Pre-releases count (unsigned builds are published as pre-releases); drafts don't.
    ///
    /// Someone on a stable version is only offered stable versions; someone already on a
    /// pre-release (a beta) is offered both.
    public static func newerRelease(than current: AppVersion, in releases: [ReleaseInfo]) -> (ReleaseInfo, AppVersion)? {
        releases
            .filter { !$0.draft }
            .compactMap { r in AppVersion(r.tagName).map { (r, $0) } }
            .filter { $0.1 > current }
            .filter { current.prerelease.isEmpty ? $0.1.prerelease.isEmpty : true }
            .max { $0.1 < $1.1 }
    }

    public static func decodeReleases(_ data: Data) throws -> [ReleaseInfo] {
        try JSONDecoder().decode([ReleaseInfo].self, from: data)
    }

    /// Reads GitHub's `releases.atom` feed. Unlike the REST API it has no anonymous rate
    /// limit (shared VPN addresses hit that quickly). Drafts never appear in the feed.
    /// Returns nil when the data isn't an Atom feed (e.g. a captive-portal page), so that is
    /// never mistaken for "no newer version".
    public static func decodeAtomReleases(_ data: Data) -> [ReleaseInfo]? {
        let parser = XMLParser(data: data)
        let reader = AtomReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse(), reader.isFeed else { return nil }
        return reader.links.compactMap { href in
            guard let url = URL(string: href), url.host == "github.com",
                  url.pathComponents.count >= 2, url.pathComponents[url.pathComponents.count - 2] == "tag" else { return nil }
            return ReleaseInfo(tagName: url.lastPathComponent, htmlURL: url, draft: false, prerelease: false)
        }
    }
}

/// Collects the alternate link of every <entry>.
private final class AtomReader: NSObject, XMLParserDelegate {
    var links: [String] = []
    var isFeed = false
    private var inEntry = false
    private var sawRoot = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if !sawRoot { sawRoot = true; isFeed = element == "feed" }
        if element == "entry" { inEntry = true }
        if inEntry, element == "link", attributes["rel"] ?? "alternate" == "alternate", let href = attributes["href"] {
            links.append(href)
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "entry" { inEntry = false }
    }
}
