import CryptoKit
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

/// Each paired phone has its own 256-bit key, named by a random key id, so one phone can be
/// forgotten without the others re-pairing, and a pairing code works once. The Mac's listener holds
/// every phone's key; TLS picks the one whose identity the phone offers. The phone then proves in its
/// hello which key it used: an HMAC of this TLS session's exporter secret, so the proof can't be
/// replayed on another connection.
public enum CompanionKeys {
    /// The TLS identity of the one key older Macs shared with every phone.
    public static let legacyIdentity = "cadence"
    /// Exporter label for the hello proof (RFC 5705 keying material from the TLS session).
    public static let exporterLabel = "EXPORTER-cadence-hello"
    public static let exporterLength = 32
    /// How long an unused pairing code keeps working.
    public static let inviteLifetime: TimeInterval = 15 * 60

    /// The TLS identity for `keyID` (nil = the legacy shared key).
    public static func identity(for keyID: String?) -> String {
        keyID.map { "cadence.\($0)" } ?? legacyIdentity
    }

    public static func newKeyID() -> String {
        var g = SystemRandomNumberGenerator()
        return PairingInvite.base64URL(Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &g) }))
    }

    public static func proof(key: Data, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: binding, using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data, key: Data, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: binding, using: SymmetricKey(data: key))
    }
}

/// Optional abilities a Mac announces with `CompanionMessage.features`, so a phone only sends what
/// the Mac understands.
public enum CompanionFeature: String, Codable, Sendable {
    /// Understands `CompanionMessage.joinMeeting`.
    case joinMeeting
}

public struct CompanionHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceID: String
    /// The name the user gave this phone in Cadence, else what iOS reports (usually just "iPhone").
    public var deviceName: String
    /// Hardware model identifier ("iPhone17,1"), so the Mac can say "iPhone 16 Pro" when the name is
    /// generic. Nil from older phones.
    public var deviceModel: String?
    /// The phone is in the foreground, in desk mode: the Mac should go quiet.
    public var displaying: Bool
    /// Which of the Mac's keys this phone holds (`CompanionKeys`), and proof that this connection
    /// was made with it. Nil from older phones, which only know the shared key.
    public var keyID: String?
    public var proof: Data?

    public init(protocolVersion: Int = CompanionService.protocolVersion, deviceID: String, deviceName: String,
                deviceModel: String? = nil, displaying: Bool, keyID: String? = nil, proof: Data? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.displaying = displaying
        self.keyID = keyID
        self.proof = proof
    }

    /// What the Mac shows for this phone.
    public var label: String { CompanionDeviceName.label(name: deviceName, model: deviceModel) }
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
    /// What assistants attached to these meetings, with the user's ticks. Nil from older Macs.
    public var enrichments: EnrichmentBook?
    /// Working hours and breaks set on the Mac. Nil from older Macs.
    public var workSchedule: WorkSchedule?

    public init(macName: String, generatedAt: Date, meetings: [Meeting], suppressedIDs: Set<String> = [],
                agendaOnlyIDs: Set<String>? = nil, takeoverEnabled: Bool = true, takeoverLeadSeconds: Double = 30, takeoverAutoDismissMinutes: Int? = nil,
                enrichments: EnrichmentBook? = nil, workSchedule: WorkSchedule? = nil) {
        self.macName = macName
        self.generatedAt = generatedAt
        self.meetings = meetings
        self.suppressedIDs = suppressedIDs
        self.agendaOnlyIDs = agendaOnlyIDs
        self.takeoverEnabled = takeoverEnabled
        self.takeoverLeadSeconds = takeoverLeadSeconds
        self.takeoverAutoDismissMinutes = takeoverAutoDismissMinutes
        self.enrichments = enrichments
        self.workSchedule = workSchedule
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
                  joinMeetingID: reminder.isSummary || reminder.isBreak || reminder.joinTarget.joinLink == nil ? nil : reminder.joinTarget.id)
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
    /// "Lands on your Lunch break", "Outside your working hours". Nil from older Macs.
    public var conflicts: [String]?

    public init(meeting: Meeting, canRespond: Bool, conflicts: [String]? = nil) {
        self.meeting = meeting
        self.canRespond = canRespond
        self.conflicts = conflicts
    }
}

/// A media player Cadence knows how to show (and, where it can, open or control).
///
/// Adding a player: the Mac's media remote control (media keys → phone) and mini-player only get
/// a track, artwork and skip for players each side can read and drive — today Music and Spotify.
/// A new player needs reading/controlling on the phone (`PhoneState.applyMediaCommand`,
/// `phoneMedia`) and on the Mac (`MacPlayers`), plus a logo and colours in `MediaLook.swift`.
public enum MediaApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleMusic, spotify, youTubeMusic, podcasts

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .youTubeMusic: "YouTube Music"
        case .podcasts: "Podcasts"
        }
    }

    /// Opens the app on iPhone.
    public var url: URL {
        switch self {
        case .appleMusic: URL(string: "music://")!
        case .spotify: URL(string: "spotify://")!
        case .youTubeMusic: URL(string: "youtubemusic://")!
        case .podcasts: URL(string: "podcasts://")!
        }
    }
}

/// What's playing on one side of the link. `title` is nil when the player doesn't share its track
/// (on iPhone, anything but the Music app).
public struct CompanionMedia: Codable, Equatable, Sendable {
    public var app: MediaApp
    public var title: String?
    public var artist: String?
    public var isPlaying: Bool
    /// Small JPEG, sent only when the track changes (nil otherwise: keep the last one).
    public var artwork: Data?
    /// Changes with the track, so the other side knows when `artwork` nil means "none".
    public var trackID: String?
    /// Whether next/previous work (only for players Cadence can control).
    public var canSkip: Bool

    public init(app: MediaApp, title: String? = nil, artist: String? = nil, isPlaying: Bool,
                artwork: Data? = nil, trackID: String? = nil, canSkip: Bool = false) {
        self.app = app
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.artwork = artwork
        self.trackID = trackID
        self.canSkip = canSkip
    }
}

public enum MediaCommand: String, Codable, Sendable {
    case play, pause, togglePlayPause, next, previous
    /// The phone's system volume, one step (of 16) at a time, from the Mac's volume keys.
    /// Older phones skip these; the Mac ignores them (its own keys already do it).
    case volumeUp, volumeDown, toggleMute

    public var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .toggleMute }
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
    /// Tick an item, mark a bingo square or log an entry on an enrichment. Older Macs skip it.
    case enrichmentAction(meetingID: String, action: EnrichmentAction)
    /// Join a meeting this Mac may not have on its own calendars (a phone paired with several Macs
    /// opening another Mac's browser link here). Only sent to Macs that list
    /// `CompanionFeature.joinMeeting`; older Macs skip it.
    case joinMeeting(Meeting)
    // Mac → Phone
    case welcome(macID: String, macName: String)
    /// Where the phone can dial the Mac directly right now, sent after `welcome` so a phone whose
    /// network blocks Bonjour keeps up with a Mac that changed address. Older phones skip it.
    case address(hosts: [String], port: UInt16)
    /// What this Mac understands beyond protocol 1 (`CompanionFeature` raw values), sent after
    /// `welcome`. Older Macs never send it; older phones skip it.
    case features([String])
    /// This phone's own key from now on, replacing the shared key older Macs gave every phone.
    /// Sent over the encrypted link; the phone uses it from its next connection. Older phones skip it.
    case rekey(keyID: String, key: Data)
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
    // Both (older peers skip these)
    /// What's playing on the sender's side; nil = nothing.
    case media(CompanionMedia?)
    /// Control the receiver's media (from its controls on the other device, or the Mac's media keys).
    case mediaCommand(MediaCommand)
    /// Phone → Mac: the phone's media volume (0...1) and whether Cadence muted it, for the Mac's
    /// mini-player. Sent when it changes. Older Macs skip it.
    case volume(level: Double, muted: Bool)
    /// Both ways every `pingInterval` (the channel sends and swallows these itself).
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
