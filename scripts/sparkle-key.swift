#!/usr/bin/env swift
// Sparkle EdDSA key file: base64 of the 32-byte Ed25519 seed (`sign_update --ed-key-file`).
// Prints only the public key (SUPublicEDKey). Never prints the private key.
//
//   swift scripts/sparkle-key.swift public <file>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3, args[1] == "public" else {
    fail("usage: sparkle-key.swift public <file>")
}
let path = (args[2] as NSString).expandingTildeInPath
guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    fail("\(path) is not a Sparkle key file (base64 of a 32-byte Ed25519 seed)")
}
print(key.publicKey.rawRepresentation.base64EncodedString())
