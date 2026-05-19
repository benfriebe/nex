import Foundation

/// Fixed-capacity ring buffer that pairs each appended value with a
/// monotonically increasing `seq`. `seq` keeps counting up even after
/// entries fall off the head, so callers can ask "give me everything
/// since seq N" without worrying about wraparound or reindexing.
///
/// Used by the web pane's console capture (Phase 3): the page can
/// produce console output faster than any CLI poll, so the buffer
/// drops oldest silently and the next streamed batch carries a
/// `dropped: <count>` line so agents know they lost something.
struct RingBuffer<Element: Equatable>: Equatable {
    /// One entry in the buffer. `seq` is unique per buffer and never
    /// recycled — even after the underlying slot is overwritten.
    struct Entry: Equatable {
        let seq: UInt64
        let value: Element
    }

    let capacity: Int
    private(set) var entries: [Entry] = []
    /// Next `seq` to assign. Always strictly greater than every seq
    /// already in `entries`.
    private(set) var nextSeq: UInt64 = 0
    /// How many entries were dropped because the buffer was full.
    /// Reset by `acknowledgeDrops`.
    private(set) var droppedSinceLastDrain: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Append `value`, evicting the oldest entry when full.
    /// Increments `droppedSinceLastDrain` on eviction.
    mutating func append(_ value: Element) {
        if entries.count >= capacity {
            entries.removeFirst()
            droppedSinceLastDrain += 1
        }
        entries.append(Entry(seq: nextSeq, value: value))
        nextSeq &+= 1
    }

    /// Return every entry whose `seq >= since`. `since == 0` yields
    /// the whole live buffer. Result is in insertion order.
    func entries(since: UInt64) -> [Entry] {
        guard since > 0 else { return entries }
        // entries[] is monotonically increasing in seq → binary search.
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].seq < since {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return Array(entries[lo...])
    }

    /// Caller has consumed a batch; reset the dropped counter so the
    /// next batch only reports drops since the last drain.
    mutating func acknowledgeDrops() -> Int {
        let n = droppedSinceLastDrain
        droppedSinceLastDrain = 0
        return n
    }

    /// Wipe everything. `seq` keeps counting — clearing doesn't reset
    /// the namespace, so callers polling with `since` see the gap.
    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
