import Foundation
import Testing
@testable import CadenceCore

private struct Inner: Codable, Equatable {
    var name = "Lunch"
    var start = 750
}

private struct Sample: Codable, Equatable {
    var enabled = true
    var lead: Double = 30
    var ratio = 0.25
    var title = "Design: \"Review\" # 1"
    var tricky = ["yes", "null", "42", "- dash", "", "it's", "multi\nline", "émoji 🎉", "  padded  "]
    var offsets = [10, 0]
    var empty: [String] = []
    var emptyMap: [String: String] = [:]
    var colours = ["cal one": "blue", "x@y.com": "red", "true": "green"]
    var breaks = [Inner(), Inner(name: "Tea", start: 900)]
    var nested = [[1, 2], [3]]
    var hotKey: String? = nil
}

private func roundTrip(_ value: Any) throws -> Any {
    try YAML.decode(YAML.encode(value))
}

private func json(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8)!
}

@Suite("YAML")
struct YAMLTests {
    @Test func roundTripsEverythingJSONCanHold() throws {
        let data = try JSONEncoder().encode(Sample())
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(try json(roundTrip(object)) == json(object))
        #expect(try JSONDecoder().decode(Sample.self, from: JSONSerialization.data(withJSONObject: roundTrip(object))) == Sample())
    }

    @Test func writesReadableBlockYAML() {
        let text = YAML.encode(["b": [1, 2], "a": ["x": true], "c": [["k": "v", "n": 1]]] as [String: Any])
        #expect(text == """
        a:
          x: true
        b:
          - 1
          - 2
        c:
          - k: "v"
            n: 1

        """)
    }

    @Test func readsHandWrittenYAML() throws {
        let text = """
        # a comment
        ---
        name: Plain text: with colon   # trailing comment
        quoted: 'it''s'
        url: https://example.com/a#b
        on: TRUE
        off: false
        none: ~
        count: -3
        half: .5
        list:
        - a
        - "b"
        flow: [1, two, "three, four"]
        map: {x: 1, "y z": null}
        items:
          - name: Lunch
            start: 750
          -
            name: Tea
        deep:
          - - 1
            - 2
        """
        let value = try YAML.decode(text) as! [String: Any]
        #expect(value["name"] as? String == "Plain text: with colon")
        #expect(value["quoted"] as? String == "it's")
        #expect(value["url"] as? String == "https://example.com/a#b")
        #expect(value["on"] as? Bool == true)
        #expect(value["off"] as? Bool == false)
        #expect(value["none"] is NSNull)
        #expect(value["count"] as? Int == -3)
        #expect(value["half"] as? Double == 0.5)
        #expect(value["list"] as? [String] == ["a", "b"])
        #expect(try json(value["flow"]!) == #"[1,"two","three, four"]"#)
        #expect(try json(value["map"]!) == #"{"x":1,"y z":null}"#)
        #expect(try json(value["items"]!) == #"[{"name":"Lunch","start":750},{"name":"Tea"}]"#)
        #expect(try json(value["deep"]!) == "[[1,2]]")
    }

    @Test func reportsWhatItCantRead() {
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a: 1\n  b: 2") }
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a: \"open") }
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a: &anchor 1") }
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a: |\n  text") }
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a: 1\na: 2") }
        #expect(throws: YAML.ParseError.self) { try YAML.decode("a:\n\t- 1") }
        #expect((try? YAML.decode("a: 1\n---\nb: 2")) == nil)
    }

    @Test func emptyDocumentIsNull() throws {
        #expect(try YAML.decode("# nothing\n\n") is NSNull)
    }
}

@Suite("Settings file")
struct SettingsArchiveTests {
    @Test func exportThenImportGivesBackTheSameSettings() throws {
        var custom = Sample()
        custom.enabled = false
        custom.title = "Changed"
        custom.hotKey = "⌘J"
        let text = try SettingsArchive.export(custom, comments: ["Hello"])
        #expect(text.hasPrefix("# Hello\n\nformat: cadence-settings\nversion: 1\nsettings:\n  breaks:\n"))
        let imported = try SettingsArchive.read(text, over: Sample())
        #expect(imported.settings == custom)
    }

    @Test func leftOutSettingsKeepTheirCurrentValue() throws {
        var current = Sample()
        current.offsets = [5]
        let text = try SettingsArchive.export(Sample(), omitting: ["offsets", "title"])
        #expect(!text.contains("offsets"))
        let imported = try SettingsArchive.read(text, over: current)
        #expect(imported.settings.offsets == [5])
        #expect(!imported.keys.contains("offsets"))
    }

    @Test func aTrimmedHandWrittenFileOnlyChangesWhatItSays() throws {
        let text = """
        format: cadence-settings
        version: 1
        settings:
          enabled: false
          breaks:
            - name: Siesta
              start: 840
        """
        let imported = try SettingsArchive.read(text, over: Sample())
        var expected = Sample()
        expected.enabled = false
        expected.breaks = [Inner(name: "Siesta", start: 840)]
        #expect(imported.settings == expected)
        #expect(imported.keys == ["breaks", "enabled"])
    }

    @Test func refusesOtherFilesAndNewerVersions() {
        #expect(throws: SettingsArchive.ArchiveError.notSettings) { try SettingsArchive.read("name: x", over: Sample()) }
        #expect(throws: SettingsArchive.ArchiveError.newerVersion(9)) {
            try SettingsArchive.read("format: cadence-settings\nversion: 9\nsettings: {}", over: Sample())
        }
        #expect(throws: SettingsArchive.ArchiveError.self) { try SettingsArchive.read("{{{", over: Sample()) }
    }

    @Test func explainsAWrongKindOfValue() {
        let text = "format: cadence-settings\nversion: 1\nsettings:\n  enabled: maybe\n"
        #expect(throws: SettingsArchive.ArchiveError.badValue("enabled should be true or false.")) {
            try SettingsArchive.read(text, over: Sample())
        }
    }
}
