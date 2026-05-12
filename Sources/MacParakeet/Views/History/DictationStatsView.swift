import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationStatsView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if viewModel.stats.isEmpty {
                    emptyState
                } else {
                    heroTiles
                    streakHeatmapCard
                    if !viewModel.topApps.isEmpty {
                        topAppsCard
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .onAppear { viewModel.refreshStatsTabData() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer(minLength: DesignSystem.Spacing.xxl)
            MeditativeMerkabaView(size: 72, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                .opacity(0.4)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Your stats will appear here.")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(.primary)
                Text(HotkeyTrigger.current.isDisabled
                     ? "Click the dictation pill or set a hotkey in Settings to start dictating."
                     : "Double-tap \(HotkeyTrigger.current.displayName) to start dictating from any app.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero Tiles

    private var heroTiles: some View {
        let stats = viewModel.stats
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md)
            ],
            spacing: DesignSystem.Spacing.md
        ) {
            heroTile(
                label: "TOTAL WORDS",
                value: stats.totalWords.compactFormatted,
                subtitle: wordsSubtitle(stats),
                icon: "text.word.spacing"
            )
            heroTile(
                label: "VOICE SPEED",
                value: stats.averageWPM.formattedWPM,
                subtitle: wpmDescriptor(stats.averageWPM),
                icon: "gauge.with.dots.needle.33percent"
            )
            heroTile(
                label: "TIME SPEAKING",
                value: stats.totalDurationMs.friendlyDuration,
                subtitle: timeSpeakingSubtitle(stats),
                icon: "clock"
            )
        }
    }

    private func heroTile(label: String, value: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(subtitle)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func wordsSubtitle(_ stats: DictationStats) -> String {
        if stats.totalWords >= 80_000 {
            let books = stats.booksEquivalent
            return String(format: "%.1f novel%@ written", books, books >= 1.5 ? "s" : "")
        } else if stats.totalWords >= 200 {
            return "\(Int(stats.emailsEquivalent)) emails worth"
        }
        return "Keep going!"
    }

    private func wpmDescriptor(_ wpm: Double) -> String {
        switch wpm {
        case ..<1: return "—"
        case ..<80: return "Thoughtful pace"
        case 80..<120: return "Conversational"
        case 120..<160: return "Brisk speaker"
        case 160..<200: return "Fast talker"
        default: return "Lightning speed"
        }
    }

    private func timeSpeakingSubtitle(_ stats: DictationStats) -> String {
        if stats.timeSavedMs >= 60_000 {
            return "Saved \(stats.timeSavedMs.friendlyDuration) typing"
        }
        return "\(stats.totalCount) dictation\(stats.totalCount == 1 ? "" : "s")"
    }

    // MARK: - Streak Heatmap

    private var streakHeatmapCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(streakHeadline)
                    .font(DesignSystem.Typography.heroTitle)
                Spacer()
                Text("LONGEST STREAK | \(viewModel.longestStreak) DAY\(viewModel.longestStreak == 1 ? "" : "S")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            StreakHeatmap(days: viewModel.dailyStats)

            HStack(spacing: DesignSystem.Spacing.md) {
                heatmapLegend
                Spacer()
                currentStreakBadge
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var streakHeadline: String {
        let n = viewModel.currentStreak
        if n == 0 { return "Build a streak" }
        return "\(n) day streak"
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(StreakHeatmap.color(for: level))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var currentStreakBadge: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(DesignSystem.Colors.accent, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Text("Current streak")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Top Apps

    private var topAppsCard: some View {
        let maxCount = viewModel.topApps.map(\.count).max() ?? 1
        let totalCount = viewModel.topApps.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate")
                    .font(DesignSystem.Typography.sectionTitle)
                Spacer()
                Text("TOP \(viewModel.topApps.count) APP\(viewModel.topApps.count == 1 ? "" : "S")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(viewModel.topApps) { entry in
                    TopAppRow(
                        entry: entry,
                        percentOfMax: Double(entry.count) / Double(max(maxCount, 1)),
                        percentOfTotal: Double(entry.count) / Double(max(totalCount, 1))
                    )
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }
}

// MARK: - Streak Heatmap

struct StreakHeatmap: View {
    let days: [DailyDictationStat]

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3
    private let weekdayLabels = ["Mon", "Wed", "Fri"] // sparse like GitHub

    var body: some View {
        // The dailyStats array is ordered oldest-first, length = 26 * 7 = 182.
        // It's a dense window ending today (inclusive) at the LAST element.
        // We pad the start of the first column with empty cells so the
        // bottom-right cell is today and the grid reads left-to-right,
        // top-to-bottom in calendar order.
        VStack(alignment: .leading, spacing: cellSpacing) {
            monthLabelRow
            HStack(alignment: .top, spacing: cellSpacing) {
                weekdayLabelColumn
                gridBody
            }
        }
    }

    private var weekdayLabelColumn: some View {
        VStack(alignment: .trailing, spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                Group {
                    if let label = weekdayLabel(forRow: row) {
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var gridBody: some View {
        let columns = buildColumns()
        return HStack(alignment: .top, spacing: cellSpacing) {
            ForEach(columns.indices, id: \.self) { colIdx in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        if let stat = columns[colIdx][row] {
                            cell(for: stat)
                        } else {
                            // Padding cell before the data window's first day,
                            // or after today (won't happen since today is the
                            // last element, but defensive).
                            Color.clear.frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    private var monthLabelRow: some View {
        // Spans columns; uses fixed approximate spacing tuned for 26 columns.
        // We compute label positions by walking the grid and surfacing the
        // first column of each month change.
        let columns = buildColumns()
        let labels = monthLabels(columns: columns)
        return HStack(alignment: .center, spacing: cellSpacing) {
            // Spacer for weekday-label column
            Color.clear.frame(width: 22, height: 10)
            ForEach(columns.indices, id: \.self) { colIdx in
                Group {
                    if let label = labels[colIdx] {
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: cellSize, height: 10, alignment: .leading)
            }
        }
    }

    private func cell(for stat: DailyDictationStat) -> some View {
        let level = Self.level(forCount: stat.count)
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(stat.day)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Self.color(for: level))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        isToday ? DesignSystem.Colors.accent : Color.clear,
                        lineWidth: isToday ? 1.5 : 0
                    )
            )
            .help(tooltip(for: stat))
    }

    private func tooltip(for stat: DailyDictationStat) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        let dateStr = df.string(from: stat.day)
        if stat.count == 0 {
            return "\(dateStr) — No dictations"
        }
        return "\(dateStr) — \(stat.count) dictation\(stat.count == 1 ? "" : "s"), \(stat.words) word\(stat.words == 1 ? "" : "s")"
    }

    // MARK: - Layout helpers

    /// Lays out `days` (oldest-first, 182 entries) into columns where each
    /// column is one calendar week (7 rows, Sun-top by default since this is
    /// macOS — uses Calendar.current.firstWeekday). Pads the leading column
    /// with `nil`s for days that fall before the window's first entry.
    private func buildColumns() -> [[DailyDictationStat?]] {
        guard !days.isEmpty else {
            return Array(repeating: Array(repeating: nil, count: 7), count: 26)
        }
        let calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday  // 1 = Sunday in en_US

        var columns: [[DailyDictationStat?]] = []
        var current: [DailyDictationStat?] = []

        // Row index for the first day: how far it sits from `firstWeekday`.
        let firstWeekdayOfData = calendar.component(.weekday, from: days[0].day)
        let leadingPad = (firstWeekdayOfData - firstWeekday + 7) % 7
        current.append(contentsOf: Array(repeating: nil as DailyDictationStat?, count: leadingPad))

        for stat in days {
            current.append(stat)
            if current.count == 7 {
                columns.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            // Pad trailing column with nils.
            current.append(contentsOf: Array(repeating: nil as DailyDictationStat?, count: 7 - current.count))
            columns.append(current)
        }
        return columns
    }

    private func weekdayLabel(forRow row: Int) -> String? {
        // Rows are 0..<7 where row 0 corresponds to firstWeekday.
        // For en_US firstWeekday=1 (Sun): Mon=row 1, Wed=row 3, Fri=row 5.
        let calendar = Calendar.current
        let weekday = ((calendar.firstWeekday - 1 + row) % 7) + 1
        // weekday 2=Mon, 4=Wed, 6=Fri
        switch weekday {
        case 2: return "Mon"
        case 4: return "Wed"
        case 6: return "Fri"
        default: return nil
        }
    }

    private func monthLabels(columns: [[DailyDictationStat?]]) -> [String?] {
        // Surface month label on the first column that begins a new month.
        let calendar = Calendar.current
        var result: [String?] = Array(repeating: nil, count: columns.count)
        var lastMonth: Int? = nil
        for (idx, column) in columns.enumerated() {
            // Use the first non-nil day in the column to detect month.
            guard let firstDay = column.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: firstDay.day)
            if month != lastMonth {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                result[idx] = formatter.string(from: firstDay.day)
                lastMonth = month
            }
        }
        return result
    }

    // MARK: - Level → Color

    static func level(forCount count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...7: return 3
        default: return 4
        }
    }

    static func color(for level: Int) -> Color {
        switch level {
        case 0: return DesignSystem.Colors.surfaceElevated
        case 1: return DesignSystem.Colors.accent.opacity(0.22)
        case 2: return DesignSystem.Colors.accent.opacity(0.45)
        case 3: return DesignSystem.Colors.accent.opacity(0.70)
        default: return DesignSystem.Colors.accent
        }
    }
}

// MARK: - Top App Row

private struct TopAppRow: View {
    let entry: DictationHistoryViewModel.TopAppEntry
    let percentOfMax: Double
    let percentOfTotal: Double

    var body: some View {
        let resolved = AppNameResolver.shared.resolve(bundleID: entry.bundleID)
        HStack(spacing: DesignSystem.Spacing.sm) {
            appIcon(for: entry.bundleID)
                .frame(width: 18, height: 18)

            Text(resolved)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated)
                    Capsule()
                        .fill(DesignSystem.Colors.accent.opacity(0.85))
                        .frame(width: max(8, geo.size.width * percentOfMax))
                }
            }
            .frame(height: 16)

            Text("\(Int((percentOfTotal * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Text("\(entry.count)")
                .font(DesignSystem.Typography.duration)
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let nsImage = AppNameResolver.shared.icon(forBundleID: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - App Name Resolver

/// Cached bundle-ID → display name + icon resolution. Hits NSWorkspace once
/// per bundle ID, then serves from the cache for the rest of the session.
@MainActor
final class AppNameResolver {
    static let shared = AppNameResolver()

    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage?] = [:]

    private init() {}

    func resolve(bundleID: String) -> String {
        if let cached = nameCache[bundleID] { return cached }
        let resolved = resolveName(bundleID: bundleID)
        nameCache[bundleID] = resolved
        return resolved
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        let image = resolveIcon(bundleID: bundleID)
        iconCache[bundleID] = image
        return image
    }

    private func resolveName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        // Prefer the localized display name (CFBundleDisplayName) → CFBundleName → URL last component.
        if let bundle = Bundle(url: url) {
            if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String { return name }
            if let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String { return name }
            if let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String { return name }
            if let name = bundle.infoDictionary?["CFBundleName"] as? String { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func resolveIcon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
