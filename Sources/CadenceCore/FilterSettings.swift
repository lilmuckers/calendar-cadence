import Foundation

/// User-defined rules deciding which events Cadence shows and alerts on.
public struct FilterSettings: Codable, Hashable, Sendable {
    /// Calendars switched off in Settings. Stored as "disabled" so new calendars appear by default.
    public var disabledCalendarIDs: Set<String> = []
    public var hideAllDay = true
    public var hideDeclined = true
    public var hideTentative = false
    public var hideFree = false
    public var onlyWithJoinLink = false
    /// Events whose title contains any of these (case-insensitive) are hidden.
    public var excludeKeywords: [String] = []
    /// When non-empty, only events whose title contains one of these are shown.
    public var includeKeywords: [String] = []
    /// Hide events shorter than this many minutes (0 = off).
    public var minimumDurationMinutes = 0

    public init() {}

    public func allows(_ meeting: Meeting) -> Bool {
        if meeting.isCanceled { return false }
        if disabledCalendarIDs.contains(meeting.calendar.id) { return false }
        if hideAllDay && meeting.isAllDay { return false }
        if hideDeclined && meeting.participation == .declined { return false }
        if hideTentative && (meeting.participation == .tentative || meeting.availability == .tentative) { return false }
        if hideFree && meeting.availability == .free { return false }
        if onlyWithJoinLink && meeting.joinLink == nil { return false }
        if minimumDurationMinutes > 0 && !meeting.isAllDay && meeting.duration < Double(minimumDurationMinutes) * 60 { return false }

        let title = meeting.title.lowercased()
        let excludes = Self.clean(excludeKeywords)
        if excludes.contains(where: { title.contains($0) }) { return false }
        let includes = Self.clean(includeKeywords)
        if !includes.isEmpty && !includes.contains(where: { title.contains($0) }) { return false }
        return true
    }

    // Missing keys fall back to defaults, so adding a filter later does not wipe saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilterSettings()
        disabledCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .disabledCalendarIDs) ?? d.disabledCalendarIDs
        hideAllDay = try c.decodeIfPresent(Bool.self, forKey: .hideAllDay) ?? d.hideAllDay
        hideDeclined = try c.decodeIfPresent(Bool.self, forKey: .hideDeclined) ?? d.hideDeclined
        hideTentative = try c.decodeIfPresent(Bool.self, forKey: .hideTentative) ?? d.hideTentative
        hideFree = try c.decodeIfPresent(Bool.self, forKey: .hideFree) ?? d.hideFree
        onlyWithJoinLink = try c.decodeIfPresent(Bool.self, forKey: .onlyWithJoinLink) ?? d.onlyWithJoinLink
        excludeKeywords = try c.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? d.excludeKeywords
        includeKeywords = try c.decodeIfPresent([String].self, forKey: .includeKeywords) ?? d.includeKeywords
        minimumDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumDurationMinutes) ?? d.minimumDurationMinutes
    }

    private static func clean(_ words: [String]) -> [String] {
        words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
