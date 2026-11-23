import Foundation
import Testing
@testable import CadenceCore

private let page = URL(string: "https://github.com/lilmuckers/calendar-cadence/releases/tag/v0")!

private func release(_ tag: String, draft: Bool = false, pre: Bool = false, body: String? = nil) -> GitHubRelease {
    GitHubRelease(tag: tag, body: body, page: page, draft: draft, prerelease: pre, assets: [
        .init(name: "Cadence-\(tag.dropFirst()).dmg", url: URL(string: "https://example.com/a.dmg")!, size: 1),
        .init(name: "Cadence-\(tag.dropFirst()).zip", url: URL(string: "https://example.com/a.zip")!, size: 2),
        .init(name: "Cadence.dmg", url: URL(string: "https://example.com/b.dmg")!, size: 1),
        .init(name: "SHA256SUMS.txt", url: URL(string: "https://example.com/sums")!, size: 3),
    ])
}

/// The body the release workflow wrote for v0.2.3.
private let realBody = """
## Cadence 0.2.3

_Released 2026-11-23 · patch release_

> [!NOTE]
> Signed with a Developer ID and notarized by Apple.

<!-- Release notes generated using configuration in .github/release.yml at v0.2.3 -->

## What's Changed
### 🐛 Fixes and improvements
* Render the downloads page's version list after each release too by @lilmuckers in https://github.com/lilmuckers/calendar-cadence/pull/59
* Request calendar.calendarlist.readonly instead of calendar.readonly by @lilmuckers in https://github.com/lilmuckers/calendar-cadence/pull/61


**Full Changelog**: https://github.com/lilmuckers/calendar-cadence/compare/v0.2.2...v0.2.3

## 📥 Install

1. Download **Cadence-0.2.3.dmg** below.

<details>
<summary>Downloads and checksums</summary>

```text
f1a13a5cffe7dce5271ca34f4b538ab067641c7f208e49ccb7830edd3bc3b5b1  Cadence-0.2.3.dmg
```
</details>
"""

@Suite("Updates")
struct UpdateTests {
    @Test func parsesVersions() {
        #expect(SemVer("v1.2.3") == SemVer(1, 2, 3))
        #expect(SemVer("0.2") == SemVer(0, 2, 0))
        #expect(SemVer("1.0.0-beta.1") == SemVer(1, 0, 0))
        #expect(SemVer("dev") == nil)
        #expect(SemVer("1.x.3") == nil)
        #expect(SemVer("1.2.3.4") == nil)
    }

    @Test func comparesNumericallyNotAlphabetically() {
        #expect(SemVer(0, 10, 0) > SemVer(0, 9, 9))
        #expect(SemVer(1, 0, 0) > SemVer(0, 99, 99))
        #expect(SemVer(0, 2, 10) > SemVer(0, 2, 9))
    }

    @Test func newestSkipsDraftsPrereleasesAndOlder() {
        let list = [release("v0.2.1"), release("v0.4.0", pre: true), release("v0.3.0", draft: true),
                    release("v0.2.10"), release("nightly")]
        #expect(UpdatePlanner.newest(in: list, newerThan: SemVer(0, 2, 1))?.tag == "v0.2.10")
        #expect(UpdatePlanner.newest(in: list, newerThan: SemVer(0, 2, 10)) == nil)
    }

    @Test func findsAssets() {
        let r = release("v0.2.3")
        #expect(UpdatePlanner.zipAsset(r)?.name == "Cadence-0.2.3.zip")
        #expect(UpdatePlanner.checksumsAsset(r)?.name == "SHA256SUMS.txt")
    }

    @Test func parsesChecksums() {
        let sums = UpdatePlanner.parseChecksums("""
        F1A13A5CFFE7DCE5271CA34F4B538AB067641C7F208E49CCB7830EDD3BC3B5B1  Cadence-0.2.3.dmg
        5658e19dd7f1b28857c8d834aacd3ded958ab2d61c37d2238460d065e8afc0e7 *Cadence-0.2.3.zip
        nonsense line
        """)
        #expect(sums["Cadence-0.2.3.zip"] == "5658e19dd7f1b28857c8d834aacd3ded958ab2d61c37d2238460d065e8afc0e7")
        #expect(sums["Cadence-0.2.3.dmg"] == "f1a13a5cffe7dce5271ca34f4b538ab067641c7f208e49ccb7830edd3bc3b5b1")
        #expect(sums.count == 2)
    }

    @Test func trimsReleaseNotesToTheChanges() {
        let notes = UpdatePlanner.releaseNotes(realBody)
        #expect(notes.hasPrefix("### 🐛 Fixes and improvements"))
        #expect(notes.contains("* Render the downloads page's version list after each release too ([#59](https://github.com/lilmuckers/calendar-cadence/pull/59))"))
        #expect(notes.hasSuffix("compare/v0.2.2...v0.2.3"))
        for gone in ["Released", "notarized", "<!--", "Install", "checksums", "@lilmuckers", "\n\n\n"] {
            #expect(!notes.contains(gone), "still contains \(gone)")
        }
    }

    @Test func changelogCoversEveryVersionSinceTheLastRun() {
        let list = [release("v0.2.0"), release("v0.2.1"), release("v0.2.2", pre: true), release("v0.2.3"), release("v0.3.0")]
        let log = UpdatePlanner.changelog(list, from: SemVer(0, 2, 0), to: SemVer(0, 2, 3))
        #expect(log.map(\.tag) == ["v0.2.3", "v0.2.1"])
        #expect(UpdatePlanner.changelog(list, from: nil, to: SemVer(0, 2, 1)).map(\.tag) == ["v0.2.1"])
    }

    @Test func decodesGitHubJSON() throws {
        let json = """
        [{"tag_name":"v0.2.3","name":"Cadence 0.2.3","body":"hi","html_url":"https://github.com/o/r/releases/tag/v0.2.3",
          "published_at":"2026-11-23T10:00:00Z","draft":false,"prerelease":false,
          "assets":[{"name":"Cadence-0.2.3.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.3/Cadence-0.2.3.zip","size":42,"extra":1}],
          "author":{"login":"x"}}]
        """
        let list = try GitHubRelease.decodeList(Data(json.utf8))
        #expect(list.first?.version == SemVer(0, 2, 3))
        #expect(list.first?.assets.first?.size == 42)
        #expect(list.first?.publishedAt != nil)
    }

    @Test func listsChangesWithTheirKind() {
        let body = """
        ## Cadence 1.0.0

        ## What's Changed
        ### 🐛 Fixes and improvements
        * Fix the thing by @lilmuckers in https://github.com/lilmuckers/calendar-cadence/pull/12
        ### 💥 Breaking changes
        * Settings reset by @lilmuckers in https://github.com/lilmuckers/calendar-cadence/pull/10
        ### ✨ New features
        * Updates by @dependabot[bot] in https://github.com/lilmuckers/calendar-cadence/pull/11
        * Another feature
        ### 📦 Other changes
        * Tidy CI by @lilmuckers in https://github.com/lilmuckers/calendar-cadence/pull/13

        **Full Changelog**: https://github.com/lilmuckers/calendar-cadence/compare/v0.9.0...v1.0.0
        """
        let changes = UpdatePlanner.changes(body)
        #expect(changes == [
            ReleaseChange(title: "Settings reset", kind: .breaking, pull: 10),
            ReleaseChange(title: "Updates", kind: .feature, pull: 11),
            ReleaseChange(title: "Another feature", kind: .feature),
            ReleaseChange(title: "Fix the thing", kind: .fix, pull: 12),
            ReleaseChange(title: "Tidy CI", kind: .other, pull: 13),
        ])
        #expect(UpdatePlanner.changes(realBody).map(\.kind) == [.fix, .fix])
        #expect(UpdatePlanner.changes(realBody).first?.title == "Render the downloads page's version list after each release too")
    }
}
