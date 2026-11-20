import CadenceCore
import SwiftUI

/// Settings sections for working hours, breaks, focus time and how breaks are defended. Shared by
/// the Mac's Work tab and the iPhone's settings; drop it inside a `Form`.
struct WorkScheduleEditor: View {
    @Binding var schedule: WorkSchedule
    /// On the phone while connected: the Mac's schedule, shown but not editable here.
    var readOnly = false
    /// Shown under the defences: which of them work on this device.
    var defencesFooter: String?

    private var calendar: Calendar { .current }

    /// Weekdays in the user's order (Monday first in most places).
    private var orderedWeekdays: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        Group {
            Section {
                Toggle("Use working hours and breaks", isOn: $schedule.enabled)
            } footer: {
                Text("Cadence gives your day a shape: before work, focus time, breaks and the end of the day. Assistants only suggest free time inside your hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Working hours") {
                ForEach(orderedWeekdays, id: \.self) { wd in
                    dayRow(wd)
                }
            }

            Section {
                ForEach($schedule.breaks) { $b in
                    breakRow($b)
                }
                Button {
                    schedule.breaks.append(WorkBreak(name: schedule.breaks.isEmpty ? "Lunch" : "Break",
                                                     start: schedule.breaks.isEmpty ? 12 * 60 + 30 : 15 * 60,
                                                     end: schedule.breaks.isEmpty ? 13 * 60 + 30 : 15 * 60 + 15))
                } label: {
                    Label("Add Break", systemImage: "plus")
                }
            } header: {
                Text("Breaks")
            } footer: {
                Text("Breaks repeat on every working day unless you pick days.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $schedule.focusMinimumMinutes, in: 15...240, step: 15) {
                    LabeledContent("Counts as focus time", value: "\(DayPlanner.duration(minutes: schedule.focusMinimumMinutes))+ clear")
                }
            } header: {
                Text("Focus time")
            }

            Section {
                Toggle("Flag invites that land on a break or outside hours", isOn: $schedule.defences.flagInvites)
                Toggle("Keep breaks out of free time for assistants", isOn: $schedule.defences.protectInFreeTime)
                Toggle("Nudge me when a break starts", isOn: $schedule.defences.breakNudge)
                Toggle("Warn when a meeting is about to run into a break", isOn: $schedule.defences.overrunWarning)
                Toggle("Ask about meetings booked over a break", isOn: $schedule.defences.clashPrompt)
            } header: {
                Text("Defend breaks")
            } footer: {
                Text(defencesFooter ?? "A meeting over a break asks like a double-booking: keep the break (the meeting won't alert) or give it up for the day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!schedule.enabled)
        }
        .disabled(readOnly)
    }

    private func dayRow(_ wd: Int) -> some View {
        let index = wd - 1
        let day = $schedule.days[index]
        return HStack {
            Toggle(calendar.weekdaySymbols[index], isOn: day.enabled)
                .fixedSize()
            Spacer()
            if schedule.days[index].enabled {
                DatePicker("Start", selection: minutes(day.start), displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("End", selection: minutes(day.end), displayedComponents: .hourAndMinute).labelsHidden()
            } else {
                Text("Day off").foregroundStyle(.secondary)
            }
        }
    }

    private func breakRow(_ b: Binding<WorkBreak>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: b.name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    schedule.breaks.removeAll { $0.id == b.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(b.wrappedValue.name)")
            }
            HStack {
                DatePicker("From", selection: minutes(b.start), displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("To", selection: minutes(b.end), displayedComponents: .hourAndMinute).labelsHidden()
                Spacer()
                Menu(daysLabel(b.wrappedValue)) {
                    Button("Every working day") { b.wrappedValue.days = nil }
                    Divider()
                    ForEach(orderedWeekdays, id: \.self) { wd in
                        Toggle(calendar.weekdaySymbols[wd - 1], isOn: dayBinding(b, wd))
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func daysLabel(_ b: WorkBreak) -> String {
        guard let days = b.days else { return "Every working day" }
        if days.isEmpty { return "No days" }
        return orderedWeekdays.filter(days.contains).map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }

    private func dayBinding(_ b: Binding<WorkBreak>, _ wd: Int) -> Binding<Bool> {
        Binding(
            get: { b.wrappedValue.days?.contains(wd) ?? schedule.day(wd).enabled },
            set: { on in
                var days = b.wrappedValue.days ?? Set((1...7).filter { schedule.day($0).enabled })
                if on { days.insert(wd) } else { days.remove(wd) }
                b.wrappedValue.days = days
            })
    }

    private func minutes(_ binding: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(binding.wrappedValue) * 60) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                binding.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
