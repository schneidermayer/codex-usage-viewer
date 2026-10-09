import SwiftUI
import WidgetKit

struct CodexUsageViewerUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct CodexUsageViewerUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexUsageViewerUsageEntry {
        CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageViewerUsageEntry) -> Void) {
        completion(CodexUsageViewerUsageEntry(date: .now, snapshot: SharedSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageViewerUsageEntry>) -> Void) {
        let now = Date.now
        let snapshot = SharedSnapshotStore.load()
        let nextReload = now.addingTimeInterval(15 * 60)
        let entries = WeeklyWidgetTimeline.dates(snapshot: snapshot, now: now, reloadAt: nextReload)
            .map { CodexUsageViewerUsageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }
}

@main
struct CodexUsageViewerWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageViewerSmallWidget()
        CodexUsageViewerUsageWidget()
    }
}

enum CodexUsageViewerWidgetSize {
    case small, large

    var name: String { self == .small ? "Small" : "Large" }
    var kind: String {
        self == .small ? CodexUsageViewerConstants.smallWidgetKind : CodexUsageViewerConstants.widgetKind
    }
    // Large uses WidgetKit's wide systemMedium family.
    var family: WidgetFamily { self == .small ? .systemSmall : .systemMedium }
}

struct CodexUsageViewerUsageWidget: Widget {
    var body: some WidgetConfiguration { usageConfiguration(size: .large) }
}

struct CodexUsageViewerSmallWidget: Widget {
    var body: some WidgetConfiguration { usageConfiguration(size: .small) }
}

@MainActor
private func usageConfiguration(size: CodexUsageViewerWidgetSize) -> some WidgetConfiguration {
    StaticConfiguration(kind: size.kind, provider: CodexUsageViewerUsageProvider()) { entry in
        CodexUsageViewerWidgetContent(snapshot: entry.snapshot, family: nil, referenceDate: entry.date)
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "codexusageviewer://dashboard"))
    }
    .configurationDisplayName(size.name)
    .description("Weekly usage, credits, available resets, and reset countdowns for your three Codex accounts.")
    .supportedFamilies([size.family])
}

#Preview("Small", as: .systemSmall) {
    CodexUsageViewerSmallWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
}

#Preview("Large", as: .systemMedium) {
    CodexUsageViewerUsageWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
    CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
}
