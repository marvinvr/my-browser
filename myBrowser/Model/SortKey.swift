import Foundation

/// Fractional index keys for ordering siblings. Keys compare lexicographically (`<` on String).
/// Inserting between two keys only creates a new key; no other record changes.
nonisolated enum SortKey {
    /// A key strictly between `a` and `b`. `nil` means open-ended (start / end).
    /// Precondition: `a < b` when both are given.
    static func between(_ a: String?, _ b: String?) -> String {
        // TODO(worker A): real base-62 fractional indexing.
        let lower = a ?? ""
        return lower + "V"
    }

    /// `count` increasing keys, e.g. for initial ordering.
    static func sequence(count: Int) -> [String] {
        var keys: [String] = []
        for _ in 0..<count { keys.append(between(keys.last, nil)) }
        return keys
    }
}
