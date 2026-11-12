// Watch-face complication: the countdown, which Always On keeps showing. The watch app reloads it on changes.
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let timer: TimerState
}

struct Provider: TimelineProvider {
    func placeholder(in _: Context) -> Entry { Entry(date: .now, timer: .start(tier: "Red", minutes: 25, phase: .focus, by: "", now: .now)) }
    func getSnapshot(in ctx: Context, completion: @escaping (Entry) -> Void) { completion(ctx.isPreview ? placeholder(in: ctx) : Entry(date: .now, timer: savedTimer())) }
    func getTimeline(in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let s = savedTimer()
        var entries = [Entry(date: .now, timer: s)]
        if s.running, let end = s.endAt { entries.append(Entry(date: Date(timeIntervalSince1970: end), timer: s)) }  // flips to "done"
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct ComplicationView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = entry.timer
        let end = Date(timeIntervalSince1970: s.endAt ?? 0)
        let live = s.running && end > entry.date
        let color = tierColor(s.tier)
        switch family {
        case .accessoryCircular:
            if live {
                ProgressView(timerInterval: Date(timeIntervalSince1970: (s.endAt ?? 0) - s.minutes * 60)...end, countsDown: true) {
                    Text("🍅")
                } currentValueLabel: {
                    Text(timerInterval: Date.now...end, countsDown: true).monospacedDigit().font(.system(size: 12))
                }
                .progressViewStyle(.circular).tint(color)
            } else {
                Image("Tomato").resizable().scaledToFit().padding(6).widgetAccentable()
            }
        case .accessoryCorner:
            Image("Tomato").resizable().scaledToFit()
                .widgetLabel { if live { Text(timerInterval: Date.now...end, countsDown: true) } else { Text(s.running ? "Done" : "Tomatime") } }
        case .accessoryInline:
            if live { Text("🍅 ") + Text(timerInterval: Date.now...end, countsDown: true) } else { Text("🍅 Tomatime") }
        default:
            VStack(alignment: .leading) {
                Text(s.phase == .idle ? "Tomatime" : s.phase == .rest ? "☕ Break" : "🍅 \(s.tier) tomato").font(.headline)
                if live {
                    Text(timerInterval: Date.now...end, countsDown: true).font(.title2.monospacedDigit()).foregroundStyle(color)
                } else {
                    Text(s.phase == .idle ? "No tomato running" : s.running ? "Done" : "Paused · \(clock(s.left))").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main struct TomatoComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TomatoComplication", provider: Provider()) { entry in
            ComplicationView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Tomato")
        .description("The tomato countdown.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}
