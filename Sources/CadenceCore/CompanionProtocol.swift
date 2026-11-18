import Foundation

/// Bonjour service the Mac advertises and the iPhone browses for.
public enum CompanionService {
    public static let type = "_cadence._tcp"
    /// Bumped when messages change incompatibly; both sides refuse a different major version.
    public static let protocolVersion = 1
    /// TXT record key holding the Mac's stable id, so a phone finds *its* Mac among several.
    public static let macIDKey = "id"
    /// A side that hears nothing for this long treats the link as gone.
    public static let timeout: TimeInterval = 15
    public static let pingInterval: TimeInterval = 5
}

public struct CompanionHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceID: String
    public var deviceName: String
    /// The phone is in the foreground, in desk mode: the Mac should go quiet.
    public var displaying: Bool

    public init(protocolVersion: Int = CompanionService.protocolVersion, deviceID: String, deviceName: String, displaying: Bool) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.displaying = displaying
    }
}

/// Everything the phone needs to mirror the Mac: its filtered, merged meetings and alert settings.
public struct CompanionSnapshot: Codable, Equatable, Sendable {
    public var macName: String
    public var generatedAt: Date
    public var meetings: [Meeting]
    /// Meetings muted because the user picked another one in a clash, or on an agenda-only calendar.
    public var suppressedIDs: Set<String>
    /// Meetings on agenda-only calendars (also in `suppressedIDs`). Nil from older Macs.
    public var agendaOnlyIDs: Set<String>?
    public var takeoverEnabled: Bool
    public var takeoverLeadSeconds: Double
    /// Minutes after the start an ignored alert closes by itself; 0 = never. Nil from older Macs.
    public var takeoverAutoDismissMinutes: Int?

    public init(macName: String, generatedAt: Date, meetings: [Meeting], suppressedIDs: Set<String> = [],
                agendaOnlyIDs: Set<String>? = nil, takeoverEnabled: Bool = true, takeoverLeadSeconds: Double = 30, takeoverAutoDismissMinutes: Int? = nil) {
        self.macName = macName
        self.generatedAt = generatedAt
        self.meetings = meetings
        self.suppressedIDs = suppressedIDs
        self.agendaOnlyIDs = agendaOnlyIDs
        self.takeoverEnabled = takeoverEnabled
        self.takeoverLeadSeconds = takeoverLeadSeconds
        self.takeoverAutoDismissMinutes = takeoverAutoDismissMinutes
    }
}

/// A heads-up / leave / wrap-up / summary reminder, already worded by the Mac.
public struct CompanionReminder: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var body: String
    /// What "Join" on this reminder opens, if anything.
    public var joinMeetingID: String?

    public init(key: String, title: String, body: String, joinMeetingID: String? = nil) {
        self.key = key
        self.title = title
        self.body = body
        self.joinMeetingID = joinMeetingID
    }

    public init(_ reminder: Reminder) {
        let text = ReminderPlanner.message(for: reminder)
        self.init(key: reminder.key, title: text.title, body: text.body,
                  joinMeetingID: reminder.isSummary || reminder.joinTarget.joinLink == nil ? nil : reminder.joinTarget.id)
    }
}

/// A double-booking the Mac wants the user to settle: alert for one meeting, or all of them.
public struct CompanionClash: Codable, Equatable, Sendable {
    public var key: String
    public var meetings: [Meeting]

    public init(key: String, meetings: [Meeting]) {
        self.key = key
        self.meetings = meetings
    }
}

/// A new invitation for the phone to pop up. `canRespond` false = the source can't send an RSVP
/// (macOS Calendar), so the phone offers to open it on the Mac instead.
public struct CompanionInvite: Codable, Equatable, Sendable {
    public var meeting: Meeting
    public var canRespond: Bool

    public init(meeting: Meeting, canRespond: Bool) {
        self.meeting = meeting
        self.canRespond = canRespond
    }
}

public enum CompanionMessage: Codable, Equatable, Sendable {
    // Phone → Mac
    case hello(CompanionHello)
    case displayState(displaying: Bool)
    case join(meetingID: String)
    case snooze(meetingID: String, seconds: Double)
    case dismiss(meetingID: String)
    /// Answer an invite from its pop-up. nil = open it in Calendar on the Mac (sources that can't RSVP).
    case rsvp(meetingID: String, reply: RSVP?)
    /// Close an invite pop-up without answering (it stays in the invite list).
    case inviteLater(meetingID: String)
    /// Settle a clash: a meeting id, "all", or nil for "decide later".
    case resolveClash(key: String, choice: String?)
    // Mac → Phone
    case welcome(macID: String, macName: String)
    /// Where the phone can dial the Mac directly right now, sent after `welcome` so a phone whose
    /// network blocks Bonjour keeps up with a Mac that changed address. Older phones skip it.
    case address(hosts: [String], port: UInt16)
    case snapshot(CompanionSnapshot)
    /// The full-screen alert for this meeting is due now.
    case alert(Meeting)
    /// The alert was handled (joined, dismissed or snoozed) on the other side.
    case dismissAlert(meetingID: String)
    case reminder(CompanionReminder)
    /// New invites to pop up while the phone is connected (the Mac holds its own card back).
    case invitePrompt([CompanionInvite])
    /// The invite was answered (on either side): close its pop-up.
    case inviteHandled(meetingID: String)
    /// A clash to settle on the phone (the Mac holds its own prompt back).
    case clashPrompt(CompanionClash)
    /// The clash was settled (on either side): close its pop-up.
    case clashHandled(key: String)
    // Both
    case ping
    case bye(reason: String)
}

/// Length-prefixed JSON frames: a 4-byte big-endian length, then that many bytes of JSON.
public enum CompanionFraming {
    public static let maxFrame = 8 * 1024 * 1024

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public static func encode(_ message: CompanionMessage) throws -> Data {
        let body = try encoder().encode(message)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    public static func decodeBody(_ body: Data) throws -> CompanionMessage {
        try decoder().decode(CompanionMessage.self, from: body)
    }
}

public enum CompanionFramingError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Collects bytes as they arrive (in any chunking) and hands back whole messages.
public struct CompanionFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends `data` and returns every complete message now available. Undecodable frames are skipped.
    public mutating func append(_ data: Data) throws -> [CompanionMessage] {
        buffer.append(data)
        var out: [CompanionMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= CompanionFraming.maxFrame else { throw CompanionFramingError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            buffer = Data(buffer[(start + 4 + length)...])
            if let message = try? CompanionFraming.decodeBody(Data(body)) { out.append(message) }
        }
        return out
    }
}
