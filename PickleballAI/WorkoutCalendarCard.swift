import SwiftUI

// MARK: - Workout calendar

struct WorkoutCalendarCard: View {
    @Environment(\.openSession) private var openSession
    let sessions: [FeedSession]
    @State private var monthAnchor = Date()
    @State private var daySessions: [FeedSession]?

    private let cal = Calendar.current

    // Locale/calendar-dependent formatters, cached so they aren't rebuilt on
    // every body evaluation (DateFormatter construction is expensive).
    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()
    private static let weekdaySymbolsFormatter = DateFormatter()

    private var workoutDays: Set<Date> {
        Set(sessions.map { cal.startOfDay(for: $0.workoutDate) })
    }

    private var sessionsByDay: [Date: [FeedSession]] {
        Dictionary(grouping: sessions) { cal.startOfDay(for: $0.workoutDate) }
    }

    private var monthTitle: String {
        Self.monthTitleFormatter.string(from: monthAnchor)
    }

    /// Day cells for the anchored month, with leading nils to align weekdays.
    private var cells: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstOfMonth = interval.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        let leading = (cal.component(.weekday, from: firstOfMonth) - cal.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<daysInMonth {
            result.append(cal.date(byAdding: .day, value: d, to: firstOfMonth))
        }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = Self.weekdaySymbolsFormatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(monthTitle).font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").foregroundStyle(Theme.textSecondary)
                }
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                }
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.4 : 1)
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    DayCell(
                        date: date,
                        worked: date.map { workoutDays.contains(cal.startOfDay(for: $0)) } ?? false,
                        isToday: date.map { cal.isDateInToday($0) } ?? false
                    ) {
                        guard let date else { return }
                        let day = sessionsByDay[cal.startOfDay(for: date)] ?? []
                        openDay(day)
                    }
                }
            }

            HStack(spacing: 14) {
                legend(color: Theme.accent, label: "Worked out")
                legend(color: Theme.surfaceElevated, label: "Rest day")
            }
            .padding(.top, 2)
        }
        .cardStyle()
        .confirmationDialog("Sessions", isPresented: daySheetBinding, titleVisibility: .visible) {
            if let daySessions {
                ForEach(daySessions) { session in
                    Button(session.workoutDisplayTitle) {
                        openSession(session.id, placeholder: session)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var daySheetBinding: Binding<Bool> {
        Binding(
            get: { (daySessions?.count ?? 0) > 1 },
            set: { if !$0 { daySessions = nil } }
        )
    }

    private func openDay(_ day: [FeedSession]) {
        guard let first = day.first else { return }
        if day.count == 1 {
            openSession(first.id, placeholder: first)
        } else {
            daySessions = day
        }
    }

    private var isCurrentMonth: Bool {
        cal.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct DayCell: View {
    let date: Date?
    let worked: Bool
    let isToday: Bool
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            if let date {
                let label = Text("\(Calendar.current.component(.day, from: date))")
                    .font(.caption.weight(worked ? .bold : .regular))
                    .foregroundStyle(worked ? Theme.background : Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(worked ? Theme.accent : Theme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(isToday ? Theme.accent : .clear, lineWidth: 1.5))

                if worked, let onTap {
                    Button(action: onTap) { label }
                        .buttonStyle(.plain)
                } else {
                    label
                }
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
