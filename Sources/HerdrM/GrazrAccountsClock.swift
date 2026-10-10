import HerdrKit
import SwiftUI

/// The Accounts sheet's clock: a 24-hour face (midnight at the top) or a week
/// (Monday at the top) with the hand at now, and a ring ahead of the hand
/// coloured by the account grazr is projected to be on, red where nothing can
/// run. Swaps are ticks across the ring; refills are numbered dots outside it.
struct GrazrAccountsClock: View {
    let report: GrazrReport
    /// `.session` is the 24-hour face, `.week` the 7-day one.
    let span: GrazrDialWindow
    let now: Date
    /// Agent names by pane id, for the legend's pinned accounts.
    var agentNames: [String: String] = [:]

    @State private var pointer: CGPoint?

    private let ringRadius: CGFloat = 112
    private let ringWidth: CGFloat = 16
    private var side: CGFloat { (ringRadius + 48) * 2 }
    private var horizon: TimeInterval { span == .week ? 7 * 86_400 : 86_400 }
    private var projection: GrazrTimeline { report.timeline(now: now, horizon: horizon) }
    private var order: [GrazrAccount] { report.dialOrder(now: now) }

    var body: some View {
        let timeline = projection
        VStack(spacing: 14) {
            ZStack {
                face
                ForEach(Array(timeline.stretches.enumerated()), id: \.offset) { _, stretch in
                    RingArc(start: turn(stretch.from), end: turn(stretch.from) + share(stretch.from, stretch.to), radius: ringRadius)
                        .stroke(color(stretch.account), style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
                }
                ForEach(Array(timeline.events.enumerated()), id: \.offset) { _, event in
                    mark(event)
                }
                RadialTick(at: turn(now), from: ringRadius - ringWidth / 2 - 8, to: ringRadius + ringWidth / 2 + 8)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                centre(timeline)
                    .frame(width: (ringRadius - ringWidth / 2 - 10) * 1.45)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer = location } else { pointer = nil }
            }
            .overlay {
                if let pointer, let tip = tip(at: pointer, in: timeline) {
                    tip
                        .fixedSize()
                        .position(x: pointer.x, y: pointer.y - 40)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary(timeline))
            Text("Projected at the current pace")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            GrazrAccountsLegend(report: report, window: span, now: now, agentNames: agentNames) { color(for: $0) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Time on the face

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// Where `date` sits on the face, as a fraction of a turn from 12 o'clock.
    private func turn(_ date: Date) -> Double {
        switch span {
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return date.timeIntervalSince(start) / (7 * 86_400)
        case .session:
            return date.timeIntervalSince(calendar.startOfDay(for: date)) / 86_400
        }
    }

    /// How much of a turn the time from `from` to `to` takes.
    private func share(_ from: Date, _ to: Date) -> Double {
        to.timeIntervalSince(from) / horizon
    }

    /// The date under a fraction of a turn: the next time the face shows it.
    private func date(at fraction: Double) -> Date {
        var ahead = fraction - turn(now)
        ahead -= ahead.rounded(.down)
        return now.addingTimeInterval(ahead * horizon)
    }

    // MARK: - Face

    private var face: some View {
        let labels: [(String, Double)] = span == .week
            ? Array(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].enumerated()).map { ($0.element, (Double($0.offset) + 0.5) / 7) }
            : [("00", 0), ("06", 0.25), ("12", 0.5), ("18", 0.75)]
        let ticks = span == .week ? 7 : 24
        return ZStack {
            RingArc(start: 0, end: 1, radius: ringRadius)
                .stroke(Theme.textGhost.opacity(0.22), style: StrokeStyle(lineWidth: ringWidth))
            ForEach(0..<ticks, id: \.self) { index in
                RadialTick(at: Double(index) / Double(ticks), from: ringRadius - ringWidth / 2 - 6, to: ringRadius - ringWidth / 2 - 2)
                    .stroke(Theme.textGhost, lineWidth: index % (span == .week ? 1 : 6) == 0 ? 1.5 : 0.75)
            }
            ForEach(labels, id: \.0) { label, fraction in
                Text(label)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .offset(ringOffset(at: fraction, radius: ringRadius + ringWidth / 2 + 30))
            }
        }
    }

    // MARK: - Ring

    private func color(_ account: GrazrAccount?) -> Color {
        account.flatMap(color(for:)) ?? Theme.danger
    }

    /// The account's colour, by its number in the rotation (the legend's).
    private func color(for account: GrazrAccount) -> Color? {
        guard let index = order.firstIndex(where: { $0.id == account.id }) else { return nil }
        return Theme.devicePalette[index % Theme.devicePalette.count]
    }

    @ViewBuilder
    private func mark(_ event: GrazrTimeline.Event) -> some View {
        switch event {
        case .swap(let at, _):
            RadialTick(at: turn(at), from: ringRadius - ringWidth / 2 - 2, to: ringRadius + ringWidth / 2 + 4)
                .stroke(Theme.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .refill(let at, let account, _):
            let number = order.firstIndex { $0.id == account.id }.map { $0 + 1 }
            Text(number.map(String.init) ?? "·")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(width: 13, height: 13)
                .background(Circle().fill(color(for: account) ?? Theme.textGhost))
                .offset(ringOffset(at: turn(at), radius: ringRadius + ringWidth / 2 + 12))
        }
    }

    // MARK: - Centre

    private func centre(_ timeline: GrazrTimeline) -> some View {
        let first = timeline.stretches.first
        let following = timeline.stretches.dropFirst().first
        let end = now.addingTimeInterval(horizon)
        return VStack(spacing: 3) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
            if span == .week {
                Text(now.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Group {
                if let first, let account = first.account {
                    Text(account.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(color(account))
                    Text(first.to >= end
                         ? String(localized: "runs past the end of the clock")
                         : String(localized: "runs until ~\(GrazrStyle.time(first.to, now: now))"))
                        .foregroundStyle(Theme.textSecondary)
                    if let following {
                        Text(following.account.map { String(localized: "then \($0.name)") } ?? String(localized: "then nothing to swap to"))
                            .foregroundStyle(following.account == nil ? Theme.danger : Theme.textSecondary)
                    }
                } else if let first {
                    Text("nothing until \(GrazrStyle.time(first.to, now: now))")
                        .foregroundStyle(Theme.danger)
                } else {
                    Text("no projection yet")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .multilineTextAlignment(.center)
    }

    private func summary(_ timeline: GrazrTimeline) -> String {
        timeline.stretches.prefix(4).map { stretch in
            let until = GrazrStyle.time(stretch.to, now: now)
            return stretch.account.map { String(localized: "\($0.name) until \(until)") }
                ?? String(localized: "nothing to run until \(until)")
        }
        .joined(separator: ", ")
    }

    // MARK: - Tip

    /// The popup for what is under `point`: a mark just outside the ring, or
    /// the stretch on it.
    private func tip(at point: CGPoint, in timeline: GrazrTimeline) -> GrazrTipBox<AnyView>? {
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        let distance = hypot(dx, dy)
        var fraction = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if fraction < 0 { fraction += 1 }
        let time = date(at: fraction)
        let outside = ringRadius + ringWidth / 2
        if distance > outside, distance <= outside + 20,
           let event = timeline.events.min(by: { abs(turn($0.at) - fraction) < abs(turn($1.at) - fraction) }),
           abs(turn(event.at) - fraction) < 0.012 {
            return GrazrTipBox { AnyView(eventTip(event)) }
        }
        guard abs(distance - ringRadius) <= ringWidth / 2 + 2,
              let index = timeline.stretches.firstIndex(where: { $0.from <= time && time < $0.to })
        else { return nil }
        let following = timeline.stretches.indices.contains(index + 1) ? timeline.stretches[index + 1] : nil
        return GrazrTipBox { AnyView(stretchTip(timeline.stretches[index], following: following)) }
    }

    @ViewBuilder
    private func stretchTip(_ stretch: GrazrTimeline.Stretch, following: GrazrTimeline.Stretch?) -> some View {
        let span = "\(GrazrStyle.time(stretch.from, now: now)) → \(GrazrStyle.time(stretch.to, now: now))"
        if let account = stretch.account {
            Text(account.name).fontWeight(.semibold).foregroundStyle(color(account))
            Text(span).foregroundStyle(Theme.text)
            if let start = stretch.leftAtStart, let end = stretch.leftAtEnd {
                Text("\(start)% → \(end)% left").foregroundStyle(Theme.textSecondary)
            }
        } else {
            let minutes = max(0, Int(stretch.to.timeIntervalSince(stretch.from) / 60))
            Text("Gap").fontWeight(.semibold).foregroundStyle(Theme.danger)
            Text("Nothing to swap to for \(minutes / 60)h \(minutes % 60)m").foregroundStyle(Theme.text)
            if let next = following?.account {
                Text("\(next.name) refills \(GrazrStyle.time(stretch.to, now: now))").foregroundStyle(Theme.textSecondary)
            } else {
                Text(span).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func eventTip(_ event: GrazrTimeline.Event) -> some View {
        switch event {
        case .swap(let at, let to):
            Text("Swap to \(to.name)").fontWeight(.semibold).foregroundStyle(color(to))
            Text(GrazrStyle.time(at, now: now)).foregroundStyle(Theme.textSecondary)
        case .refill(let at, let account, let group):
            Text(account.name).fontWeight(.semibold).foregroundStyle(color(account))
            Text(group == "session" ? String(localized: "5-hour window refills") : String(localized: "week resets"))
                .foregroundStyle(Theme.text)
            Text(GrazrStyle.time(at, now: now)).foregroundStyle(Theme.textSecondary)
        }
    }
}
