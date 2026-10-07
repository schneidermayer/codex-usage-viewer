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
struct CodexUsageViewerUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CodexUsageViewerConstants.widgetKind, provider: CodexUsageViewerUsageProvider()) { entry in
            CodexUsageViewerWidgetContent(snapshot: entry.snapshot, family: nil, referenceDate: entry.date)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "codexusageviewer://dashboard"))
        }
        .configurationDisplayName("Codex Usage Viewer")
        .description("Weekly usage and time until reset for your three Codex accounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview("Three accounts", as: .systemMedium) {
    CodexUsageViewerUsageWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
}

#Preview("Connect accounts", as: .systemLarge) {
    CodexUsageViewerUsageWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
}
