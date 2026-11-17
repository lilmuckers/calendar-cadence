import AppKit
import CadenceCore
import SwiftUI

/// `Cadence.app/Contents/MacOS/Cadence --screenshots <dir>` renders the real views with demo data
/// to PNGs for the README (docs/screenshots). Nothing here runs in normal use.
@MainActor
enum ScreenshotRenderer {
    static func run(state: AppState, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        VisualEffect.screenshotFill = Color(white: 0.13, opacity: 0.86)
        MenuBarView.screenshotMode = true
        state.persistPrefs = false
        state.demoMode = true
        state.prefs.takeoverLeadSeconds = 30

        let demo = Demo()
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { demo.day.addingTimeInterval(Double(h * 3600 + m * 60 + s)) }

        // Menu bar dropdown + countdown panel: mid-morning, Design Review is 7 minutes away.
        state.loadDemo(demo.meetings, calendars: demo.calendars, now: at(10, 52, 41))
        render(MenuBarView(), state: state, name: "menu", to: dir, size: CGSize(width: 380, height: 640), wallpaper: true, pad: 28)
        render(CountdownPanelView(), state: state, name: "panel", to: dir, size: CGSize(width: 300, height: 92), wallpaper: true, pad: 28)
        for style in [PanelStyle.compact, .mini] {
            state.prefs.panelStyle = style
            render(CountdownPanelView(), state: state, name: "panel-\(style.rawValue)", to: dir, size: style.size, wallpaper: true, pad: 20)
        }
        state.prefs.panelStyle = .standard
        render(FakeMenuBar(state: state), state: state, name: "menubar", to: dir, size: CGSize(width: 560, height: 30), wallpaper: false, pad: 0)

        // 23 seconds before Design Review.
        state.loadDemo(demo.meetings, calendars: demo.calendars, now: at(10, 59, 37))
        let design = demo.meetings.first { $0.title == "Design Review" }!
        render(TakeoverView(meeting: design, isPrimary: true, actions: .init(snooze: {}, dismiss: {})),
               state: state, name: "takeover", to: dir, size: CGSize(width: 1440, height: 900), wallpaper: true, pad: 0)
        render(BannerView(meeting: design, dismiss: {}), state: state, name: "banner", to: dir,
               size: CGSize(width: 460, height: 64), wallpaper: true, pad: 28)

        // The afternoon clash.
        state.loadDemo(demo.meetings, calendars: demo.calendars, now: at(10, 52, 41))
        if let clash = state.clashes.first {
            render(ClashPromptView(clash: clash, choose: { _ in }), state: state, name: "clash", to: dir,
                   size: CGSize(width: 340, height: CGFloat(118 + clash.meetings.count * 54)), wallpaper: true, pad: 28)
        }

        // Invite review card.
        let model = InviteReviewModel()
        model.items = demo.invites
        model.reason = .daily
        state.prefs.colorPromptCalendarIDs = [demo.work.id]
        render(InviteReviewView(model: model, close: {}, changed: {}), state: state, name: "invites", to: dir,
               size: CGSize(width: 360, height: 76 + 116 + 84 + 84), wallpaper: true, pad: 28)
        state.prefs.colorPromptCalendarIDs = []

        // The three moods of the menu bar icon, big.
        render(Moods(), state: state, name: "moods", to: dir, size: CGSize(width: 360, height: 110), wallpaper: false, pad: 0)
        print("Screenshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, state: AppState, name: String, to dir: URL, size: CGSize, wallpaper: Bool, pad: CGFloat) {
        let content = view
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: pad > 0 ? 14 : 0, style: .continuous))
            .shadow(color: .black.opacity(pad > 0 ? 0.45 : 0), radius: 24, y: 12)
            .padding(pad)
            .background { if wallpaper { Wallpaper() } }
            .environment(state)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Failed to render \(name)")
            return
        }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// A moody desktop for the glass to sit on.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.07, blue: 0.22), Color(red: 0.05, green: 0.10, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.54).opacity(0.45)).frame(width: 520).blur(radius: 140).offset(x: -260, y: -160)
            Circle().fill(Color(red: 1.0, green: 0.82, blue: 0.25).opacity(0.30)).frame(width: 420).blur(radius: 140).offset(x: 300, y: 200)
            Circle().fill(Color(red: 0.35, green: 0.45, blue: 1.0).opacity(0.40)).frame(width: 460).blur(radius: 140).offset(x: 240, y: -220)
        }
    }
}

private struct FakeMenuBar: View {
    let state: AppState
    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            MenuBarLabel(state: state).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(state.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.10, blue: 0.20))
    }
}

private struct Moods: View {
    var body: some View {
        HStack(spacing: 40) {
            ForEach([("Calm", MenuBarIcon.Mood.calm), ("15 min", .nervous), ("5 min", .panicking)], id: \.0) { label, mood in
                VStack(spacing: 8) {
                    Image(nsImage: MenuBarIcon.image(mood)).renderingMode(.template).resizable()
                        .frame(width: 60, height: 54).foregroundStyle(.white)
                    Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.10, blue: 0.20))
    }
}

/// A believable Tuesday.
private struct Demo {
    let day = Calendar.current.startOfDay(for: Date())

    let work = CalendarInfo(id: "work", title: "Work", sourceTitle: "Google", color: RGBAColor(red: 0.36, green: 0.52, blue: 1.0))
    let sales = CalendarInfo(id: "sales", title: "Sales", sourceTitle: "Exchange", color: RGBAColor(red: 1.0, green: 0.58, blue: 0.22))
    let personal = CalendarInfo(id: "me", title: "Personal", sourceTitle: "iCloud", color: RGBAColor(red: 0.30, green: 0.80, blue: 0.48))
    let team = CalendarInfo(id: "team", title: "Team", sourceTitle: "Subscribed feeds", color: RGBAColor(red: 0.75, green: 0.45, blue: 1.0))

    var calendars: [CalendarInfo] { [work, sales, personal, team] }

    var invites: [Meeting] {
        func inv(_ title: String, days: Int, _ h: Int, _ cal: CalendarInfo, from: String, recurs: Bool = false) -> Meeting {
            let start = day.addingTimeInterval(Double(days * 86_400 + h * 3600))
            return Meeting(id: "invite-\(title)", title: title, start: start, end: start.addingTimeInterval(1800), calendar: cal,
                           organizer: from, attendeeCount: 6, participation: .pending, recurs: recurs)
        }
        return [
            inv("Q1 Kick-off", days: 0, 15, work, from: "Priya Shah"),
            inv("Pricing Workshop", days: 1, 10, sales, from: "Jordan Lee"),
            inv("Weekly Design Crit", days: 1, 14, team, from: "Sam Okafor", recurs: true),
        ]
    }

    var meetings: [Meeting] {
        func m(_ title: String, _ h: Int, _ min: Int, _ len: Int, _ cal: CalendarInfo, link: String? = nil,
               location: String? = nil, people: Int = 0) -> Meeting {
            let start = day.addingTimeInterval(Double(h * 3600 + min * 60))
            return Meeting(id: "demo-\(title)", title: title, start: start, end: start.addingTimeInterval(Double(len * 60)),
                           calendar: cal, location: location, attendeeCount: people, participation: .accepted,
                           joinLink: link.flatMap { MeetingLinkDetector.firstMeetingLink(in: $0) })
        }
        return [
            m("Daily Standup", 9, 30, 15, team, link: "https://us02web.zoom.us/j/81234567890", people: 8),
            m("Sprint Planning", 10, 15, 45, work, link: "https://teams.microsoft.com/l/meetup-join/abc", people: 6),
            m("Design Review", 11, 0, 45, work, link: "https://meet.google.com/abc-defg-hij", people: 5),
            m("Lunch with Priya", 12, 30, 60, personal, location: "Dishoom, 22 Kingly St, London"),
            m("Roadmap Planning", 14, 0, 60, work, link: "https://teams.microsoft.com/l/meetup-join/def", people: 9),
            m("Customer Call — Acme", 14, 30, 30, sales, link: "https://acme.zoom.us/j/99887766", people: 4),
            m("1:1 with Sam", 16, 0, 30, work, link: "https://meet.google.com/xyz-abcd-efg", people: 2),
            m("Climbing", 18, 30, 90, personal, location: "The Castle Climbing Centre, London"),
        ]
    }
}
