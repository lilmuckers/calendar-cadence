import CadenceCore
import SwiftUI

/// Settings sections for working hours, breaks, focus time and how breaks are defended. Shared by
/// the Mac's Work tab and the iPhone's settings; drop it inside a grouped `Form`.
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

    private static let focusChoices = [30, 45, 60, 90, 120]

    var body: some View {
        Group {
            Section {
                Toggle("Use working hours and breaks", isOn: $schedule.enabled)
            } footer: {
                footer("Gives your day a shape — before work, focus time, breaks, the end of the day — and keeps assistants' suggestions inside your hours.")
            }

            Group {
                Section("Working hours") {
                    ForEach(orderedWeekdays, id: \.self) { dayRow($0) }
                }

                Section {
                    ForEach($schedule.breaks) { breakRow($0) }
                    Button {
                        let first = schedule.breaks.isEmpty
                        schedule.breaks.append(WorkBreak(name: first ? "Lunch" : "Break",
                                                         start: first ? 12 * 60 + 30 : 15 * 60,
                                                         end: first ? 13 * 60 + 30 : 15 * 60 + 15))
                    } label: {
                        Label("Add Break", systemImage: "plus")
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                } header: {
                    Text("Breaks")
                } footer: {
                    footer("Each break repeats on every working day unless you pick days.")
                }

                Section {
                    Picker("Focus time is a clear stretch of at least", selection: $schedule.focusMinimumMinutes) {
                        ForEach(Self.focusChoices + (Self.focusChoices.contains(schedule.focusMinimumMinutes) ? [] : [schedule.focusMinimumMinutes]),
                                id: \.self) { Text(DayPlanner.duration(minutes: $0)).tag($0) }
                    }
                } header: {
                    Text("Focus time")
                }

                Section {
                    Toggle("Flag invites on a break or outside hours", isOn: $schedule.defences.flagInvites)
                    Toggle("Keep breaks out of assistants' free time", isOn: $schedule.defences.protectInFreeTime)
                    Toggle("Nudge me when a break starts", isOn: $schedule.defences.breakNudge)
                    Toggle("Warn before a meeting runs into a break", isOn: $schedule.defences.overrunWarning)
                    Toggle("Ask about meetings booked over a break", isOn: $schedule.defences.clashPrompt)
                } header: {
                    Text("Defend breaks")
                } footer: {
                    footer(defencesFooter ?? "A meeting over a break asks like a double-booking: keep the break (the meeting won't alert) or give it up for the day.")
                }
            }
            .disabled(!schedule.enabled)
        }
        .disabled(readOnly)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Rows

    /// "☑ Monday          09:00 – 17:30", or "Day off".
    private func dayRow(_ wd: Int) -> some View {
        let day = $schedule.days[wd - 1]
        return HStack {
            #if os(macOS)
            Toggle(calendar.weekdaySymbols[wd - 1], isOn: day.enabled)
                .toggleStyle(.checkbox)
            #else
            Text(calendar.weekdaySymbols[wd - 1])
            #endif
            Spacer()
            if day.wrappedValue.enabled {
                timeRange(day.start, day.end)
            } else {
                Text("Day off").foregroundStyle(.secondary)
            }
            #if !os(macOS)
            Toggle("", isOn: day.enabled).labelsHidden()
            #endif
        }
    }

    /// One line on the Mac: name, times, days, remove. Two on the phone.
    private func breakRow(_ b: Binding<WorkBreak>) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            TextField("Name", text: b.name)
                .labelsHidden()
                .frame(width: 110)
            timeRange(b.start, b.end)
            daysMenu(b)
            Spacer(minLength: 0)
            removeButton(b.wrappedValue)
        }
        #else
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: b.name).font(.body.weight(.semibold))
                removeButton(b.wrappedValue)
            }
            HStack {
                timeRange(b.start, b.end)
                Spacer()
                daysMenu(b)
            }
        }
        .padding(.vertical, 2)
        #endif
    }

    private func timeRange(_ start: Binding<Int>, _ end: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            DatePicker("From", selection: minutes(start), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("–").foregroundStyle(.secondary)
            DatePicker("To", selection: minutes(end), displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        #if os(macOS)
        // The standard compact field with stepper arrows, like the rest of Settings.
        .datePickerStyle(.stepperField)
        #endif
        .fixedSize()
    }

    private func daysMenu(_ b: Binding<WorkBreak>) -> some View {
        Menu(daysLabel(b.wrappedValue)) {
            Button("Every working day") { b.wrappedValue.days = nil }
            Divider()
            ForEach(orderedWeekdays, id: \.self) { wd in
                Toggle(calendar.weekdaySymbols[wd - 1], isOn: dayBinding(b, wd))
            }
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }

    private func removeButton(_ b: WorkBreak) -> some View {
        Button(role: .destructive) {
            schedule.breaks.removeAll { $0.id == b.id }
        } label: {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove \(b.name)")
        .accessibilityLabel("Remove \(b.name)")
    }

    private func daysLabel(_ b: WorkBreak) -> String {
        guard let days = b.days else { return "Every day" }
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
