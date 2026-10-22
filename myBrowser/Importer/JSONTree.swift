import Foundation

/// Small casts over `JSONSerialization` values. Parsing stays off the main actor.
nonisolated enum JSONTree {
    static func object(from data: Data) -> [String: Any]? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func dictionary(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }

    static func string(_ any: Any?) -> String? {
        any as? String
    }

    static func strings(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func double(_ any: Any?) -> Double? {
        if let number = any as? Double { return number }
        if let number = any as? NSNumber { return number.doubleValue }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let number = any as? Int { return number }
        if let number = any as? NSNumber { return number.intValue }
        return nil
    }

    /// Objects stored as `[id, object, id, object, …]`, in that order.
    static func pairedObjects(_ any: Any?) -> [[String: Any]] {
        guard let array = any as? [Any] else { return [] }
        var objects: [[String: Any]] = []
        var index = 0
        while index < array.count {
            if index + 1 < array.count,
               array[index] is String,
               let object = array[index + 1] as? [String: Any] {
                objects.append(object)
                index += 2
            } else if let object = array[index] as? [String: Any] {
                objects.append(object)
                index += 1
            } else {
                index += 1
            }
        }
        return objects
    }

    /// `[descriptor, id, descriptor, id, …]`. The descriptor's first key is the tag.
    static func taggedIDs(_ any: Any?) -> [(tag: String, id: String, payload: [String: Any])] {
        guard let array = any as? [Any] else { return [] }
        var pairs: [(tag: String, id: String, payload: [String: Any])] = []
        var index = 0
        while index + 1 < array.count {
            let left = array[index]
            let right = array[index + 1]
            if let payload = left as? [String: Any], let id = right as? String, let tag = payload.keys.first {
                pairs.append((tag, id, payload))
                index += 2
            } else if let id = left as? String, let payload = right as? [String: Any], let tag = payload.keys.first {
                pairs.append((tag, id, payload))
                index += 2
            } else {
                index += 1
            }
        }
        return pairs
    }

    /// Arc wraps an associated value in `_0`.
    static func unwrap(_ any: Any?) -> Any? {
        guard let dictionary = any as? [String: Any], dictionary.count == 1, let inner = dictionary["_0"] else {
            return any
        }
        return inner
    }
}
