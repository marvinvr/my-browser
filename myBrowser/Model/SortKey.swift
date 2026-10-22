import Foundation

/// Fractional index keys for ordering siblings. Keys compare lexicographically (`<` on String).
///
/// Same scheme as the "fractional-indexing" algorithm: a base-62 fractional part
/// (`0-9A-Za-z`) and a base-52 integer head (`A-Z` negative magnitudes, `a-z` positive)
/// so appending and prepending stay short. The fractional part never ends in `0`,
/// which leaves room to insert before any key. Inserting between two keys only
/// creates a new key; no other record changes.
nonisolated enum SortKey {
    /// `0-9A-Za-z`. Digits of the fractional part and of the integer part after its head.
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    /// `A-Za-z`. The first half marks negative integer lengths, the second half positive ones.
    private static let intDigits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static let digitIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })
    private static let intDigitIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: intDigits.enumerated().map { ($1, $0) })

    /// Smallest integer (`A` plus 26 zeros). Not a valid key; one step below the key space.
    private static let smallestInteger: String = String(intDigits[0]) + String(repeating: digits[0], count: intDigits.count / 2)

    /// A key strictly between `a` and `b`. `nil` means open-ended (start / end).
    /// Precondition: `a < b` when both are given, and both keys are valid order keys.
    static func between(_ a: String?, _ b: String?) -> String {
        if let a { validate(a) }
        if let b { validate(b) }
        if let a, let b {
            precondition(a < b, "SortKey.between requires a < b")
        }

        guard let a else {
            guard let b else {
                return String(intDigits[intDigits.count / 2]) + String(digits[0])
            }
            return key(before: b)
        }
        guard let b else {
            return key(after: a)
        }
        return key(between: a, and: b)
    }

    /// `count` increasing keys, e.g. for initial ordering.
    static func sequence(count: Int) -> [String] {
        precondition(count >= 0)
        var keys: [String] = []
        keys.reserveCapacity(count)
        for _ in 0..<count {
            keys.append(between(keys.last, nil))
        }
        return keys
    }

    private static func key(before b: String) -> String {
        let ib = integerPart(of: b)
        let fb = String(b.dropFirst(ib.count))
        if ib == smallestInteger {
            return ib + midpoint("", fb)
        }
        if ib < b {
            return ib
        }
        guard let decremented = decrementInteger(ib) else {
            preconditionFailure("cannot decrement any more")
        }
        return decremented
    }

    private static func key(after a: String) -> String {
        let ia = integerPart(of: a)
        let fa = String(a.dropFirst(ia.count))
        if let incremented = incrementInteger(ia) {
            return incremented
        }
        return ia + midpoint(fa, nil)
    }

    private static func key(between a: String, and b: String) -> String {
        let ia = integerPart(of: a)
        let fa = String(a.dropFirst(ia.count))
        let ib = integerPart(of: b)
        let fb = String(b.dropFirst(ib.count))
        if ia == ib {
            return ia + midpoint(fa, fb)
        }
        guard let incremented = incrementInteger(ia) else {
            preconditionFailure("cannot increment any more")
        }
        if incremented < b {
            return incremented
        }
        return ia + midpoint(fa, nil)
    }

    // MARK: - Midpoint

    /// Midpoint of two fractional parts. An empty `b` is the open end, matching the reference algorithm.
    private static func midpoint(_ a: String, _ b: String?) -> String {
        let b = (b?.isEmpty == false) ? b : nil
        let zero = digits[0]
        if let b {
            precondition(a < b, "midpoint requires a < b")
            precondition(b.last != zero, "trailing zero")
        }
        if let last = a.last {
            precondition(last != zero, "trailing zero")
        }

        if let b {
            let aChars = Array(a)
            let bChars = Array(b)
            var n = 0
            while n < bChars.count {
                let aChar = n < aChars.count ? aChars[n] : zero
                if aChar != bChars[n] { break }
                n += 1
            }
            if n > 0 {
                let prefix = String(bChars.prefix(n))
                let aRest = n < aChars.count ? String(aChars.dropFirst(n)) : ""
                let bRest = bChars.dropFirst(n)
                return prefix + midpoint(aRest, bRest.isEmpty ? nil : String(bRest))
            }
        }

        let digitA = a.first.map(digitValue) ?? 0
        let digitB = b?.first.map(digitValue) ?? digits.count
        if digitB - digitA > 1 {
            let mid = (digitA + digitB + 1) / 2
            return String(digits[mid])
        }
        if let b, b.count > 1, let first = b.first {
            return String(first)
        }
        let rest = a.isEmpty ? "" : String(a.dropFirst())
        return String(digits[digitA]) + midpoint(rest, nil)
    }

    // MARK: - Integers

    private static func validate(_ key: String) {
        precondition(key != smallestInteger, "invalid order key: \(key)")
        guard let head = key.first else {
            preconditionFailure("invalid order key")
        }
        let length = integerLength(of: head)
        precondition(length <= key.count, "invalid order key: \(key)")
        let fraction = key.dropFirst(length)
        if let last = fraction.last {
            precondition(last != digits[0], "invalid order key: \(key)")
        }
        for character in key.dropFirst() {
            precondition(digitIndex[character] != nil, "invalid order key: \(key)")
        }
    }

    private static func integerPart(of key: String) -> String {
        guard let head = key.first else {
            preconditionFailure("invalid order key")
        }
        let length = integerLength(of: head)
        precondition(length <= key.count, "invalid order key: \(key)")
        return String(key.prefix(length))
    }

    /// Head `A`…`Z` lengthen as they move away from `Z`; `a`…`z` lengthen as they move away from `a`.
    private static func integerLength(of head: Character) -> Int {
        guard let index = intDigitIndex[head] else {
            preconditionFailure("invalid order key head: \(head)")
        }
        let half = intDigits.count / 2
        return index < half ? half - index + 1 : index - half + 2
    }

    private static func digitValue(_ character: Character) -> Int {
        guard let value = digitIndex[character] else {
            preconditionFailure("invalid digit \(character)")
        }
        return value
    }

    /// Next integer, or nil at the top of the key space.
    private static func incrementInteger(_ x: String) -> String? {
        let chars = Array(x)
        guard let head = chars.first else {
            preconditionFailure("empty integer")
        }
        precondition(chars.count == integerLength(of: head), "invalid integer part: \(x)")
        let zero = digits[0]
        var trailing: [Character] = []
        var index = chars.count - 1
        while index >= 1 {
            let next = digitValue(chars[index]) + 1
            if next == digits.count {
                trailing.insert(zero, at: 0)
                index -= 1
            } else {
                let middle = chars[1..<index]
                return String([head] + middle + [digits[next]] + trailing)
            }
        }
        guard let headIndex = intDigitIndex[head], headIndex + 1 < intDigits.count else { return nil }
        let newHead = intDigits[headIndex + 1]
        return String(newHead) + adjusted(trailing, delta: integerLength(of: newHead) - chars.count, pad: zero)
    }

    /// Previous integer, or nil at the bottom of the key space.
    private static func decrementInteger(_ x: String) -> String? {
        let chars = Array(x)
        guard let head = chars.first else {
            preconditionFailure("empty integer")
        }
        precondition(chars.count == integerLength(of: head), "invalid integer part: \(x)")
        let lastDigit = digits[digits.count - 1]
        var trailing: [Character] = []
        var index = chars.count - 1
        while index >= 1 {
            let next = digitValue(chars[index]) - 1
            if next == -1 {
                trailing.insert(lastDigit, at: 0)
                index -= 1
            } else {
                let middle = chars[1..<index]
                return String([head] + middle + [digits[next]] + trailing)
            }
        }
        guard let headIndex = intDigitIndex[head], headIndex > 0 else { return nil }
        let newHead = intDigits[headIndex - 1]
        return String(newHead) + adjusted(trailing, delta: integerLength(of: newHead) - chars.count, pad: lastDigit)
    }

    /// Grow or shrink the carried digit run so it matches the new head's length.
    private static func adjusted(_ trailing: [Character], delta: Int, pad: Character) -> String {
        var body = trailing
        if delta > 0 {
            body.append(pad)
        } else if delta < 0, !body.isEmpty {
            body.removeFirst()
        }
        return String(body)
    }
}
