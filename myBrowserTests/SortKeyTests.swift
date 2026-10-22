import Foundation
import Testing
@testable import myBrowser

@MainActor
struct SortKeyTests {
    @Test func midpointAndKnownVectors() {
        let first = SortKey.between(nil, nil)
        #expect(first == "a0")

        let second = SortKey.between(first, nil)
        let third = SortKey.between(second, nil)
        #expect(second == "a1")
        #expect(third == "a2")
        #expect(first < second)
        #expect(second < third)

        let beforeFirst = SortKey.between(nil, first)
        #expect(beforeFirst == "Zz")
        #expect(beforeFirst < first)
        #expect(SortKey.between(nil, beforeFirst) == "Zy")

        #expect(SortKey.between(second, third) == "a1V")
        #expect(SortKey.between(first, second) == "a0V")
        #expect(SortKey.between(first, third) == "a1")
        #expect(SortKey.between(beforeFirst, first) == "ZzV")

        let prefixed = SortKey.sequence(count: 63)
        #expect(prefixed[61] == "az")
        #expect(prefixed[62] == "b00")
        #expect(SortKey.between(nil, prefixed[62]) == "az")
    }

    @Test func equalOrOutOfOrderKeysDoNotTrap() {
        let lower = SortKey.between(nil, nil)
        let upper = SortKey.between(lower, nil)
        let afterEqual = SortKey.between(lower, lower)
        #expect(afterEqual > lower)
        let afterReversed = SortKey.between(upper, lower)
        #expect(afterReversed > upper)
        let afterSame = SortKey.between("a2", "a2")
        #expect(afterSame > "a2")
    }

    @Test func betweenIsStrictAndOpenEnded() {
        let keys = SortKey.sequence(count: 20)
        for key in keys {
            #expect(SortKey.between(nil, key) < key)
            #expect(SortKey.between(key, nil) > key)
        }
        for index in keys.indices.dropLast() {
            let mid = SortKey.between(keys[index], keys[index + 1])
            #expect(keys[index] < mid)
            #expect(mid < keys[index + 1])
        }
    }

    @Test func sequenceIsIncreasingAndShort() {
        #expect(SortKey.sequence(count: 0).isEmpty)
        let keys = SortKey.sequence(count: 100)
        #expect(keys.count == 100)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.count <= 3 })
    }

    @Test func appendAndPrependStayShort() {
        var appended = SortKey.between(nil, nil)
        var appendLength = appended.count
        for _ in 0..<500 {
            let next = SortKey.between(appended, nil)
            #expect(next > appended)
            appended = next
            appendLength = max(appendLength, next.count)
        }

        var prepended = SortKey.between(nil, nil)
        var prependLength = prepended.count
        for _ in 0..<500 {
            let next = SortKey.between(nil, prepended)
            #expect(next < prepended)
            prepended = next
            prependLength = max(prependLength, next.count)
        }

        #expect(appendLength <= 4)
        #expect(prependLength <= 4)
    }

    @Test func repeatedInsertsInOneGapStayOrdered() {
        let lower = SortKey.between(nil, nil)
        let upper = SortKey.between(lower, nil)
        var keys = [lower]
        for _ in 0..<50 {
            let mid = SortKey.between(keys[keys.count - 1], upper)
            #expect(keys[keys.count - 1] < mid)
            #expect(mid < upper)
            keys.append(mid)
        }
        #expect(Set(keys).count == keys.count)
    }

    @Test func randomInsertionsKeepOrderAndUniqueness() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var keys = [SortKey.between(nil, nil)]
        for _ in 0..<1000 {
            let index = Int.random(in: 0...keys.count, using: &rng)
            let lower = index > 0 ? keys[index - 1] : nil
            let upper = index < keys.count ? keys[index] : nil
            let key = SortKey.between(lower, upper)
            if let lower { #expect(key > lower) }
            if let upper { #expect(key < upper) }
            keys.insert(key, at: index)
        }

        #expect(keys.count == 1001)
        #expect(Set(keys).count == keys.count)
        #expect(keys == keys.sorted())

        for index in keys.indices.dropLast() {
            let mid = SortKey.between(keys[index], keys[index + 1])
            #expect(keys[index] < mid)
            #expect(mid < keys[index + 1])
        }
    }
}

/// Deterministic generator so a failing insertion sequence can be replayed.
nonisolated private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
