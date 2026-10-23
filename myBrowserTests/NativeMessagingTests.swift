import Foundation
import Testing
@testable import myBrowser

struct NativeMessagingTests {
    @Test func framesRoundTrip() throws {
        let object: [String: Any] = ["ping": "pong", "n": 2]
        let framed = try NativeMessageFraming.frame(object)
        var buffer = framed
        let bodies = try NativeMessageFraming.drain(&buffer)
        #expect(buffer.isEmpty)
        #expect(bodies.count == 1)
        let decoded = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(decoded["ping"] as? String == "pong")
        #expect(decoded["n"] as? Int == 2 || (decoded["n"] as? NSNumber)?.intValue == 2)
    }

    @Test func drainKeepsAPartialFrame() throws {
        let framed = try NativeMessageFraming.frame(["ok": true])
        var buffer = Data(framed.prefix(3))
        let early = try NativeMessageFraming.drain(&buffer)
        #expect(early.isEmpty)
        buffer.append(framed.dropFirst(3))
        let bodies = try NativeMessageFraming.drain(&buffer)
        #expect(bodies.count == 1)
        #expect(buffer.isEmpty)
    }

    @Test func oversizedLengthIsRejected() {
        var buffer = Data([0x01, 0x00, 0x00, 0x80])
        #expect(throws: NativeMessagingError.messageTooLarge) {
            _ = try NativeMessageFraming.drain(&buffer)
        }
    }

    @Test func catalogMatchesTheExtensionOrigin() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nmh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "host.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let origin = NativeMessagingCatalog.chromeOrigin(extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        let manifest: [String: Any] = [
            "name": "com.example.host",
            "description": "test",
            "path": script.path,
            "type": "stdio",
            "allowed_origins": [origin],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: directory.appending(path: "com.example.host.json"))
        let found = NativeMessagingCatalog.locate(
            name: "com.example.host",
            extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
            origin: origin,
            directories: [directory],
            allowWellKnownFallback: false
        )
        guard case .success(let loaded) = found else {
            Issue.record("expected a host, got \(found)")
            return
        }
        #expect(loaded.executablePath == script.path)

        let denied = NativeMessagingCatalog.locate(
            name: "com.example.host",
            extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            origin: NativeMessagingCatalog.chromeOrigin(extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            directories: [directory],
            allowWellKnownFallback: false
        )
        guard case .failure(.originNotAllowed(_)) = denied else {
            Issue.record("expected originNotAllowed, got \(denied)")
            return
        }
    }

    @Test func hostEchoesOneFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nmh-echo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "echo.py")
        let source = """
        #!/usr/bin/python3
        import json, struct, sys
        header = sys.stdin.buffer.read(4)
        if len(header) < 4:
            sys.exit(1)
        n = struct.unpack('=I', header)[0]
        body = json.loads(sys.stdin.buffer.read(n))
        out = json.dumps({"echo": body}).encode()
        sys.stdout.buffer.write(struct.pack('=I', len(out)))
        sys.stdout.buffer.write(out)
        sys.stdout.buffer.flush()
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = EchoOnce { result in
                continuation.resume(with: result)
            }
            do {
                let process = try NativeMessagingProcess.start(
                    executable: script,
                    origin: "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
                    onFrame: { once.succeed($0) },
                    onClose: { _ in once.fail(NativeMessagingError.hostExited(nil)) }
                )
                once.process = process
                try process.send(["ping": "pong"])
            } catch {
                once.fail(error)
            }
        }
        let echoed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inner = try #require(echoed["echo"] as? [String: Any])
        #expect(inner["ping"] as? String == "pong")
    }
}

nonisolated private final class EchoOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let finish: @Sendable (Result<Data, Error>) -> Void
    var process: NativeMessagingProcess?

    init(_ finish: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.finish = finish
    }

    func succeed(_ value: Data) { complete(.success(value)) }

    func fail(_ error: Error) { complete(.failure(error)) }

    private func complete(_ result: Result<Data, Error>) {
        lock.lock()
        let first = !done
        done = true
        let process = self.process
        self.process = nil
        lock.unlock()
        guard first else { return }
        process?.stop()
        finish(result)
    }
}
