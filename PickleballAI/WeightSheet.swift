import Charts
import SwiftUI

// MARK: - Weight

/// The weight logger. Three beats, top to bottom: what you weigh **now**, how
/// it has moved, and every weigh-in behind it. Everything on this screen is
/// private to the signed-in user (see `AppStore+Weight`).
struct WeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var range: WeightRange = .threeMonths
    @State private var logTarget: WeightLogTarget?
    @State private var showsGoalSheet = false
    @State private var scrubbedDay: Date?

    /// Newest first — the order the log is stored and listed in.
    private var entries: [WeightEntry] { store.weightEntries }
    private var unit: WeightUnit { store.weightUnit }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.isInitialWeightLoading && entries.isEmpty {
                        SkeletonList(rows: 4)
                    } else if entries.isEmpty {
                        emptyState
                    } else {
                        heroCard
                        logButton
                        chartCard
                        historyCard
                    }

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.loss)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .refreshable {
                guard let uid = store.currentProfile?.id else { return }
                await store.loadWeightLog(userId: uid)
            }
            .onAppear { store.errorMessage = nil }
            .sheet(item: $logTarget) { target in
                WeightEntrySheet(target: target)
            }
            .sheet(isPresented: $showsGoalSheet) {
                WeightGoalSheet()
            }
        }
    }

    // MARK: Hero

    private var latest: WeightEntry? { entries.first }

    /// Change across the selected range: latest minus the earliest weigh-in
    /// still inside it. `nil` until there are two points to compare.
    private var rangeDelta: Double? {
        guard let latest, let first = series.first, series.count > 1 else { return nil }
        return latest.weightPounds - first.weightPounds
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("CURRENT")
                    .font(.caption2.weight(.heavy))
                    .kerning(1.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                unitToggle
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(latest.map { unit.display(pounds: $0.weightPounds) } ?? "—")
                    .font(.system(size: 58, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: latest?.weightPounds)
                    .foregroundStyle(Theme.textPrimary)
                Text(unit.label)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let rangeDelta {
                    deltaChip(rangeDelta)
                }
                if let latest {
                    Text(latest.day.weightLogRelativeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            goalRow
        }
        .padding(16)
        .background {
            // A single lime bloom behind the readout — the one moment of colour
            // on an otherwise black card, clipped so it can't wash the layout.
            ZStack(alignment: .topTrailing) {
                Theme.surface
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 220, height: 220)
                    .blur(radius: 80)
                    .opacity(0.18)
                    .offset(x: 70, y: -90)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    /// Down is *not* automatically good — the colour tracks movement toward the
    /// user's own goal, and stays neutral when they haven't set one.
    private func deltaChip(_ delta: Double) -> some View {
        let tint: Color
        if let goal = store.weightGoalPounds, let latest {
            let before = latest.weightPounds - delta
            tint = abs(latest.weightPounds - goal) <= abs(before - goal) ? Theme.accent : Theme.loss
        } else {
            tint = Theme.textSecondary
        }
        return HStack(spacing: 4) {
            Image(systemName: delta < 0 ? "arrow.down.right" : (delta > 0 ? "arrow.up.right" : "equal"))
                .font(.caption2.weight(.black))
            Text(unit.displayDelta(pounds: delta))
                .font(.caption.weight(.bold))
                .monospacedDigit()
            Text(range.shortCaption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint.opacity(0.7))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private var unitToggle: some View {
        HStack(spacing: 2) {
            ForEach(WeightUnit.allCases) { option in
                Button {
                    Haptics.tap()
                    Task { await store.setWeightUnit(option) }
                } label: {
                    Text(option.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(unit == option ? Theme.background : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(unit == option ? Theme.accent : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.surfaceElevated, in: Capsule())
        .animation(.snappy(duration: 0.2), value: unit)
    }

    @ViewBuilder
    private var goalRow: some View {
        Button {
            Haptics.tap()
            showsGoalSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                if let goal = store.weightGoalPounds {
                    Text("Goal \(unit.displayWithUnit(pounds: goal))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let latest {
                        let remaining = abs(latest.weightPounds - goal)
                        Text(remaining < 0.05
                             ? "reached"
                             : "\(unit.display(pounds: remaining)) \(unit.label) to go")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("Set a goal weight")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var logButton: some View {
        Button {
            Haptics.impact()
            logTarget = WeightLogTarget(day: Date())
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entries.contains(where: \.isToday) ? "pencil" : "plus")
                    .font(.subheadline.weight(.heavy))
                Text(entries.contains(where: \.isToday) ? "Edit today's weigh-in" : "Log today's weight")
                    .font(.headline)
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    // MARK: Chart

    /// Oldest → newest, clipped to the selected range. Chart order.
    private var series: [WeightEntry] {
        let start = range.start(from: Date())
        return entries
            .filter { start == nil || $0.day >= start! }
            .sorted { $0.day < $1.day }
    }

    /// 7-day moving average. Day-to-day weight is mostly water; the trend line
    /// is what actually answers "am I moving?", so it gets drawn alongside the
    /// raw points rather than replacing them.
    private var trend: [WeightTrendPoint] {
        guard series.count >= 4 else { return [] }
        let window: TimeInterval = 6 * 24 * 60 * 60
        return series.map { point in
            let bucket = series.filter { $0.day <= point.day && $0.day >= point.day.addingTimeInterval(-window) }
            let mean = bucket.reduce(0) { $0 + $1.weightPounds } / Double(bucket.count)
            return WeightTrendPoint(day: point.day, pounds: mean)
        }
    }

    private func plotted(_ pounds: Double) -> Double { unit.fromPounds(pounds) }

    /// Weight charts must never be pinned to zero — a 3 lb move on a 0–170
    /// axis is a flat line. Pad the real span instead, with a floor so a single
    /// point doesn't collapse into a zero-height domain.
    private var yDomain: ClosedRange<Double> {
        var values = series.map { plotted($0.weightPounds) } + trend.map { plotted($0.pounds) }
        if let goal = store.weightGoalPounds { values.append(plotted(goal)) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.25, unit == .pounds ? 1.5 : 0.7)
        return (low - pad)...(high + pad)
    }

    /// The x-axis spans the *selected window*, not the data extent. Without
    /// this, two weigh-ins a day apart zoom the axis into a single day and
    /// every tick prints the same date — and "Last 3 months" would silently
    /// show three days.
    private var xDomain: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        let windowStart = range.start(from: Date()) ?? series.first?.day ?? today
        let start = min(windowStart, series.first?.day ?? windowStart)
        let end = max(today, series.last?.day ?? today)
        // All-time with a single day of history still needs a non-empty domain.
        guard start < end else {
            return (end.addingTimeInterval(-7 * 24 * 60 * 60))...end
        }
        return start...end
    }

    private var scrubbed: WeightEntry? {
        guard let scrubbedDay else { return nil }
        return series.min { abs($0.day.timeIntervalSince(scrubbedDay)) < abs($1.day.timeIntervalSince(scrubbedDay)) }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(range.caption)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !trend.isEmpty {
                    HStack(spacing: 5) {
                        Capsule()
                            .fill(Theme.textTertiary)
                            .frame(width: 14, height: 2)
                        Text("7-day trend")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            rangeSelector

            if series.count < 2 {
                Text("One weigh-in in this range. Log another to see the line move.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                chart
            }
        }
        .cardStyle()
    }

    private var chart: some View {
        Chart {
            ForEach(series) { entry in
                AreaMark(
                    x: .value("Day", entry.day),
                    yStart: .value("Floor", yDomain.lowerBound),
                    yEnd: .value("Weight", plotted(entry.weightPounds))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(series) { entry in
                LineMark(
                    x: .value("Day", entry.day),
                    y: .value("Weight", plotted(entry.weightPounds)),
                    series: .value("Series", "weight")
                )
                // Monotone, not catmullRom: a smoothing curve that overshoots
                // would draw weights the user never actually recorded.
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            ForEach(trend) { point in
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Trend", plotted(point.pounds)),
                    series: .value("Series", "trend")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }

            if showsPoints {
                ForEach(series) { entry in
                    PointMark(
                        x: .value("Day", entry.day),
                        y: .value("Weight", plotted(entry.weightPounds))
                    )
                    .symbolSize(26)
                    .foregroundStyle(Theme.accent)
                }
            }

            if let goal = store.weightGoalPounds {
                RuleMark(y: .value("Goal", plotted(goal)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("GOAL")
                            .font(.system(size: 9, weight: .black))
                            .kerning(0.8)
                            .foregroundStyle(Theme.accent.opacity(0.7))
                    }
            }

            if let scrubbed {
                RuleMark(x: .value("Day", scrubbed.day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.courtLine)
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        callout(for: scrubbed)
                    }
                PointMark(
                    x: .value("Day", scrubbed.day),
                    y: .value("Weight", plotted(scrubbed.weightPounds))
                )
                .symbolSize(90)
                .foregroundStyle(Theme.accent)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXSelection(value: $scrubbedDay)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: range.axisFormat).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 190)
    }

    /// Dots stop helping once they merge into the line.
    private var showsPoints: Bool { series.count <= 40 }

    private func callout(for entry: WeightEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(unit.displayWithUnit(pounds: entry.weightPounds))
                .font(.caption.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(entry.day, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private var rangeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WeightRange.allCases) { option in
                    Button {
                        Haptics.tap()
                        scrubbedDay = nil
                        withAnimation(.snappy(duration: 0.2)) { range = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(range == option ? Theme.background : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(range == option ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: History

    /// Newest first, capped — the chart carries the long view, this is the
    /// recent record you actually want to correct.
    private var history: [WeightEntry] { Array(entries.prefix(60)) }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(entries.count) logged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 6)

            ForEach(Array(history.enumerated()), id: \.element.id) { index, entry in
                let previous = index + 1 < history.count ? history[index + 1] : nil
                Button {
                    Haptics.tap()
                    logTarget = WeightLogTarget(day: entry.day)
                } label: {
                    WeightHistoryRow(
                        entry: entry,
                        delta: previous.map { entry.weightPounds - $0.weightPounds },
                        unit: unit
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { logTarget = WeightLogTarget(day: entry.day) }
                    Button("Delete", role: .destructive) {
                        Haptics.warning()
                        Task { await store.deleteWeightEntry(entry) }
                    }
                }
                if entry.id != history.last?.id {
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .cardStyle()
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scalemass.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("No weigh-ins yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Log your weight and it starts charting. Only you can see it.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            logButton
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardStyle()
    }
}

// MARK: - History row

private struct WeightHistoryRow: View {
    let entry: WeightEntry
    let delta: Double?
    let unit: WeightUnit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if entry.isToday {
                    Text("Today")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            if let delta, abs(delta) >= 0.05 {
                Text(unit.displayDelta(pounds: delta))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(unit.displayWithUnit(pounds: entry.weightPounds))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Chart support

/// Chart windows for the weight log. Weight moves slowly, so the shortest
/// useful window is a month — a week of points says almost nothing.
enum WeightRange: String, CaseIterable, Identifiable {
    case month = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case year = "1Y"
    case all = "All"

    var id: String { rawValue }

    /// `nil` means "no lower bound" — the whole log.
    var days: Int? {
        switch self {
        case .month:       return 30
        case .threeMonths: return 90
        case .sixMonths:   return 182
        case .year:        return 365
        case .all:         return nil
        }
    }

    func start(from date: Date) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: date))
    }

    var caption: String {
        switch self {
        case .month:       return "Last 30 days"
        case .threeMonths: return "Last 3 months"
        case .sixMonths:   return "Last 6 months"
        case .year:        return "Last 12 months"
        case .all:         return "All time"
        }
    }

    /// Trailing half of the delta chip ("−2.4 lb · 3 months").
    var shortCaption: String {
        switch self {
        case .month:       return "· 30 days"
        case .threeMonths: return "· 3 months"
        case .sixMonths:   return "· 6 months"
        case .year:        return "· 12 months"
        case .all:         return "· all time"
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .month:                 return .dateTime.month(.abbreviated).day()
        case .threeMonths, .sixMonths: return .dateTime.month(.abbreviated).day()
        case .year, .all:            return .dateTime.month(.narrow)
        }
    }
}

struct WeightTrendPoint: Identifiable, Hashable {
    let day: Date
    let pounds: Double
    var id: Date { day }
}

extension WeightEntry {
    var isToday: Bool { Calendar.current.isDateInToday(day) }
}

extension Date {
    /// "Today" / "Yesterday" / "Mar 4" for the hero's timestamp line.
    var weightLogRelativeLabel: String {
        if Calendar.current.isDateInToday(self) { return "Today" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
