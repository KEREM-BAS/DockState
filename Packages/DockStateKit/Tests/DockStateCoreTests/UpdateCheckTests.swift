import Foundation
import Testing
@testable import DockStateCore

@Suite struct UpdateCheckTests {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    @Test func parsing() {
        #expect(v("v1.2.3").description == "1.2.3")
        #expect(v("2").description == "2.0.0")
        #expect(v("1.3.0-beta.2").prerelease == ["beta", "2"])
        #expect(v("1.0.0+build.5").description == "1.0.0")
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
    }

    @Test func ordering() {
        #expect(v("1.2.3") < v("1.2.10"))
        #expect(v("1.0.0-beta") < v("1.0.0"))
        #expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(v("0.9.9") < v("1.0.0-beta"))
        #expect(v("1.0") == v("1.0.0"))
    }

    @Test func picksNewestPublishedRelease() throws {
        let json = """
        [{"tag_name":"v0.3.0","html_url":"https://github.com/x/y/releases/tag/v0.3.0","draft":true,"prerelease":false},
         {"tag_name":"v0.2.1","html_url":"https://github.com/x/y/releases/tag/v0.2.1","draft":false,"prerelease":true},
         {"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","draft":false,"prerelease":false},
         {"tag_name":"nightly","html_url":"https://github.com/x/y/releases/tag/nightly","draft":false,"prerelease":true}]
        """
        let releases = try UpdateCheck.decodeReleases(Data(json.utf8))
        let newer = UpdateCheck.newerRelease(than: v("0.1.0"), in: releases)
        #expect(newer?.1 == v("0.2.1"))
        #expect(UpdateCheck.newerRelease(than: v("0.2.1"), in: releases) == nil)
    }

    @Test func readsTheAtomFeed() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <link type="text/html" rel="alternate" href="https://github.com/KEREM-BAS/DockState/releases"/>
          <title>Release notes from DockState</title>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/KEREM-BAS/DockState/releases/tag/v0.2.0"/>
            <title>DockState 0.2.0</title>
          </entry>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/KEREM-BAS/DockState/releases/tag/v0.1.0"/>
            <title>DockState 0.1.0</title>
          </entry>
        </feed>
        """
        let releases = UpdateCheck.decodeAtomReleases(Data(feed.utf8)) ?? []
        #expect(releases.map(\.tagName) == ["v0.2.0", "v0.1.0"])
        #expect(UpdateCheck.newerRelease(than: v("0.1.0"), in: releases)?.1 == v("0.2.0"))
        // An empty feed is "no releases"; anything that isn't a feed is a failure.
        #expect(UpdateCheck.decodeAtomReleases(Data("<feed/>".utf8)) == [])
        #expect(UpdateCheck.decodeAtomReleases(Data("not xml".utf8)) == nil)
        #expect(UpdateCheck.decodeAtomReleases(Data("<html><body>Sign in to Wi-Fi</body></html>".utf8)) == nil)
    }

    @Test func malformedVersionsDontCrash() {
        for s in ["", "v", "+", "1.0.0-+", "-", "1..2", ".1", "1.0.0-"] {
            #expect(AppVersion(s) == nil, "\(s)")
        }
    }

    @Test func stableUsersAreNotOfferedBetas() {
        let url = URL(string: "https://github.com/x/y/releases/tag/v1.1.0-beta.1")!
        let beta = ReleaseInfo(tagName: "v1.1.0-beta.1", htmlURL: url, draft: false, prerelease: true)
        let stable = ReleaseInfo(tagName: "v1.1.0", htmlURL: url, draft: false, prerelease: false)
        #expect(UpdateCheck.newerRelease(than: v("1.0.0"), in: [beta]) == nil)
        #expect(UpdateCheck.newerRelease(than: v("1.1.0-beta.1"), in: [stable])?.1 == v("1.1.0"))
        #expect(UpdateCheck.newerRelease(than: v("1.0.0-beta.1"), in: [beta])?.1 == v("1.1.0-beta.1"))
    }
}
