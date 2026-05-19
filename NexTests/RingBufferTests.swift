import Foundation
@testable import Nex
import Testing

struct RingBufferTests {
    @Test func emptyOnInit() {
        let buf = RingBuffer<Int>(capacity: 4)
        #expect(buf.isEmpty)
        #expect(buf.count == 0)
        #expect(buf.nextSeq == 0)
        #expect(buf.droppedSinceLastDrain == 0)
    }

    @Test func appendUnderCapacityKeepsEverything() {
        var buf = RingBuffer<Int>(capacity: 4)
        buf.append(10)
        buf.append(20)
        buf.append(30)
        #expect(buf.count == 3)
        #expect(buf.entries.map(\.value) == [10, 20, 30])
        #expect(buf.entries.map(\.seq) == [0, 1, 2])
        #expect(buf.nextSeq == 3)
        #expect(buf.droppedSinceLastDrain == 0)
    }

    @Test func appendOverCapacityEvictsOldestAndCountsDrops() {
        var buf = RingBuffer<Int>(capacity: 3)
        for n in 1 ... 5 {
            buf.append(n)
        }
        #expect(buf.count == 3)
        #expect(buf.entries.map(\.value) == [3, 4, 5])
        // seqs keep counting; the evicted entries had seq 0 and 1.
        #expect(buf.entries.map(\.seq) == [2, 3, 4])
        #expect(buf.nextSeq == 5)
        #expect(buf.droppedSinceLastDrain == 2)
    }

    @Test func sinceZeroReturnsEverything() {
        var buf = RingBuffer<Int>(capacity: 4)
        for n in 0 ..< 3 {
            buf.append(n)
        }
        let all = buf.entries(since: 0)
        #expect(all.map(\.value) == [0, 1, 2])
    }

    @Test func sinceMidwayReturnsTail() {
        var buf = RingBuffer<Int>(capacity: 10)
        for n in 0 ..< 6 {
            buf.append(n * 10)
        }
        // seq 3 → values 30, 40, 50 (entries[3...])
        let tail = buf.entries(since: 3)
        #expect(tail.map(\.value) == [30, 40, 50])
        #expect(tail.map(\.seq) == [3, 4, 5])
    }

    @Test func sinceBeyondNextSeqReturnsEmpty() {
        var buf = RingBuffer<Int>(capacity: 4)
        buf.append(1)
        buf.append(2)
        #expect(buf.entries(since: 99).isEmpty)
    }

    @Test func sinceAcrossEvictionReturnsOnlyLiveTail() {
        var buf = RingBuffer<Int>(capacity: 3)
        for n in 0 ..< 5 {
            buf.append(n)
        } // live: seq 2,3,4 → values 2,3,4
        // Caller asks since=1 — that seq has been evicted, so they
        // should get every live entry (the binary search lands at lo=0).
        let result = buf.entries(since: 1)
        #expect(result.map(\.seq) == [2, 3, 4])
        #expect(result.map(\.value) == [2, 3, 4])
    }

    @Test func acknowledgeDropsResetsCounter() {
        var buf = RingBuffer<Int>(capacity: 2)
        for n in 0 ..< 5 {
            buf.append(n)
        }
        #expect(buf.droppedSinceLastDrain == 3)
        let drained = buf.acknowledgeDrops()
        #expect(drained == 3)
        #expect(buf.droppedSinceLastDrain == 0)
        // Drains are additive across calls — append more and check.
        buf.append(99)
        buf.append(100)
        #expect(buf.droppedSinceLastDrain == 2)
    }

    @Test func clearEmptiesButPreservesSeqNamespace() {
        var buf = RingBuffer<Int>(capacity: 4)
        for n in 0 ..< 3 {
            buf.append(n)
        }
        buf.clear()
        #expect(buf.isEmpty)
        #expect(buf.nextSeq == 3) // unchanged
        buf.append(99)
        #expect(buf.entries.map(\.seq) == [3])
    }
}
