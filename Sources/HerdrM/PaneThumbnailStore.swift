import AppKit

/// An image the user pasted or typed a path for, waiting to be matched to the
/// bordered `#N` box Claude Code draws for it.
struct PendingThumbnail: Equatable {
    var image: NSImage
    var name: String
    var recordedAt: Date
    /// Seconds the entry may wait for its box: 60 for typed paths, 10 for a local ^V.
    var expiry: TimeInterval
}

/// A thumbnail ready to be drawn into the interior of a box.
struct PlacedThumbnail: Equatable {
    var box: ClaudeImageBox
    var image: NSImage
}

/// Decides which pasted image belongs to which box, so a wrong thumbnail is
/// never drawn: when the number of new boxes differs from the number of live
/// pending images, nothing binds. Pure state; all time comes in as `now`.
struct PaneThumbnailStore {
    /// How long a bound number survives without its box being seen before the
    /// number counts as new again (Claude resets its counter after a send).
    static let graceAfterDisappearing: TimeInterval = 30

    private struct Binding {
        var image: NSImage
        var lastSeen: Date
    }

    private var pending: [PendingThumbnail] = []
    private var bound: [Int: Binding] = [:]
    /// Visible numbers that never got an image. They are not "new" on later
    /// scans, so a later paste cannot bind to a box that was already there.
    private var seen: [Int: Date] = [:]

    /// Queues an image to be matched to the next new box(es), in delivery order.
    mutating func record(_ pending: PendingThumbnail) {
        self.pending.append(pending)
    }

    /// Applies the binding rules to the boxes a scan found and returns what to draw, ascending by box number.
    mutating func scan(_ boxes: [ClaudeImageBox], now: Date) -> [PlacedThumbnail] {
        pending.removeAll { now.timeIntervalSince($0.recordedAt) > $0.expiry }
        bound = bound.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.graceAfterDisappearing }

        seen = seen.filter { now.timeIntervalSince($0.value) <= Self.graceAfterDisappearing }

        let newNumbers = Set(boxes.map(\.number).filter { bound[$0] == nil && seen[$0] == nil }).sorted()
        if !newNumbers.isEmpty {
            if newNumbers.count == pending.count {
                for (number, entry) in zip(newNumbers, pending) {
                    bound[number] = Binding(image: entry.image, lastSeen: now)
                }
            }
            pending.removeAll()
        }

        for box in boxes {
            if bound[box.number] != nil {
                bound[box.number]?.lastSeen = now
            } else {
                seen[box.number] = now
            }
        }
        return boxes.sorted { $0.number < $1.number }.compactMap { box in
            bound[box.number].map { PlacedThumbnail(box: box, image: $0.image) }
        }
    }

    /// Right before a delivery: drops every binding and every seen-unbound
    /// number whose box is not on screen now. Claude's counter can reset
    /// (`/clear`, a relaunch) inside the grace, and its next `#1` must count as
    /// new, or the old `#1` image would be painted into the new paste's box.
    /// Ordinary scans keep the grace, so scrolling still keeps an image.
    mutating func forgetAbsentBindings(present boxes: [ClaudeImageBox]) {
        let present = Set(boxes.map(\.number))
        bound = bound.filter { present.contains($0.key) }
        seen = seen.filter { present.contains($0.key) }
    }

    /// What `scan` would draw for `boxes` from the current bindings, without
    /// binding, marking anything seen, or refreshing a binding: for the scans
    /// held while a delivery is in flight, which may only move or remove overlays.
    func placements(for boxes: [ClaudeImageBox], now: Date) -> [PlacedThumbnail] {
        boxes.sorted { $0.number < $1.number }.compactMap { box in
            guard let binding = bound[box.number],
                  now.timeIntervalSince(binding.lastSeen) <= Self.graceAfterDisappearing
            else { return nil }
            return PlacedThumbnail(box: box, image: binding.image)
        }
    }

    /// True while a scan could still change something: a live pending entry
    /// exists or a binding is bound.
    func needsScanning(now: Date) -> Bool {
        pending.contains { now.timeIntervalSince($0.recordedAt) <= $0.expiry }
            || bound.values.contains { now.timeIntervalSince($0.lastSeen) <= Self.graceAfterDisappearing }
    }

    mutating func removeAll() {
        pending.removeAll()
        bound.removeAll()
        seen.removeAll()
    }
}
