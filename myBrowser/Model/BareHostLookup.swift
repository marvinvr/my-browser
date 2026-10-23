import Darwin
import Foundation
import Synchronization

/// Whether a bare single-label name (`photos`) resolves.
///
/// Tailscale MagicDNS answers these through the system resolver, search domain included.
/// A timeout is a miss and is not cached, so a later Enter can try again.
nonisolated enum BareHostLookup {
    private final class Store: Sendable {
        let cache = Mutex<[String: Bool]>([:])
        let inflight = Mutex<[String: Task<Bool?, Never>]>([:])
    }

    private static let store = Store()

    static func cached(_ name: String) -> Bool? {
        let key = name.lowercased()
        return store.cache.withLock { $0[key] }
    }

    static func resolves(_ name: String) async -> Bool {
        let key = name.lowercased()
        if let hit = cached(key) { return hit }
        let task = task(for: key)
        guard let found = await task.value else { return false }
        store.cache.withLock { $0[key] = found }
        return found
    }

    private static func task(for key: String) -> Task<Bool?, Never> {
        store.inflight.withLock { inflight in
            if let existing = inflight[key] { return existing }
            let task = Task.detached(priority: .userInitiated) { () -> Bool? in
                let value = lookup(key)
                store.inflight.withLock { $0[key] = nil }
                return value
            }
            inflight[key] = task
            return task
        }
    }

    /// `nil` when the resolver does not answer in time.
    private static func lookup(_ name: String) -> Bool? {
        let answer = AnswerBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(name, nil, &hints, &info)
            if let info { freeaddrinfo(info) }
            answer.value = (code == 0)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .milliseconds(300)) == .success else { return nil }
        return answer.value
    }

    private final class AnswerBox: @unchecked Sendable {
        var value: Bool?
    }
}
