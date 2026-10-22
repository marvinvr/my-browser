import CryptoKit
import Foundation

/// Strips a Chrome extension package (CRX2 or CRX3) down to the ZIP payload.
///
/// CRX2 is `Cr24`, version, public-key length, signature length, key, signature, ZIP.
/// CRX3 is `Cr24`, version, header size, a protobuf header, ZIP.
nonisolated enum CRXArchive {
    struct Payload: Equatable, Sendable {
        var version: UInt32
        var zip: Data
        /// Chrome extension id (32 characters, a–p) when the header carries a key or a crx id.
        var extensionID: String?
    }

    enum Failure: Error, Equatable, Sendable {
        case notCRX
        case truncated
        case unsupportedVersion(UInt32)
    }

    private static let alphabet = Array("abcdefghijklmnop")
    private static let maxHeader = 1_048_576

    static func payload(from data: Data) throws -> Payload {
        guard data.count >= 16 || (data.count >= 8 && uint32(data, 4) == 3 && data.count >= 12) else {
            if data.count >= 4, !data.prefix(4).elementsEqual(Data("Cr24".utf8)) {
                throw Failure.notCRX
            }
            throw Failure.truncated
        }
        guard data.prefix(4).elementsEqual(Data("Cr24".utf8)) else { throw Failure.notCRX }
        let version = uint32(data, 4)
        switch version {
        case 2:
            return try payloadV2(data)
        case 3:
            return try payloadV3(data)
        default:
            throw Failure.unsupportedVersion(version)
        }
    }

    /// Chrome's extension id: first 16 bytes of SHA-256(public key), each nibble mapped to a–p.
    static func extensionID(publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return encodeID(Data(digest.prefix(16)))
    }

    /// A raw 16-byte crx id, already the value Chrome stores in the CRX3 signed header.
    static func extensionID(crxID bytes: Data) -> String? {
        guard bytes.count == 16 else { return nil }
        return encodeID(bytes)
    }

    static func encodeID(_ bytes: Data) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0f)])
        }
        return out
    }

    private static func payloadV2(_ data: Data) throws -> Payload {
        guard data.count >= 16 else { throw Failure.truncated }
        let keyLength = Int(uint32(data, 8))
        let signatureLength = Int(uint32(data, 12))
        guard keyLength >= 0, signatureLength >= 0, keyLength <= maxHeader, signatureLength <= maxHeader else {
            throw Failure.truncated
        }
        let zipStart = 16 + keyLength + signatureLength
        guard data.count >= zipStart else { throw Failure.truncated }
        let key = data.subdata(in: 16..<(16 + keyLength))
        let zip = data.subdata(in: zipStart..<data.count)
        let identifier = key.isEmpty ? nil : extensionID(publicKey: key)
        return Payload(version: 2, zip: zip, extensionID: identifier)
    }

    private static func payloadV3(_ data: Data) throws -> Payload {
        guard data.count >= 12 else { throw Failure.truncated }
        let headerSize = Int(uint32(data, 8))
        guard headerSize >= 0, headerSize <= maxHeader else { throw Failure.truncated }
        let zipStart = 12 + headerSize
        guard data.count >= zipStart else { throw Failure.truncated }
        let header = data.subdata(in: 12..<zipStart)
        let zip = data.subdata(in: zipStart..<data.count)
        return Payload(version: 3, zip: zip, extensionID: extensionID(in: header))
    }

    /// CRX3 `CrxFileHeader`: field 2/3 are key proofs (field 1 is the public key), field 10000 is signed data (field 1 is the 16-byte id).
    private static func extensionID(in header: Data) -> String? {
        var fromKey: String?
        for (field, value) in protoFields(header) {
            guard case .bytes(let payload) = value else { continue }
            if field == 10_000 {
                for (inner, innerValue) in protoFields(payload) {
                    guard inner == 1, case .bytes(let id) = innerValue, let encoded = extensionID(crxID: id) else { continue }
                    return encoded
                }
            } else if field == 2 || field == 3 {
                for (inner, innerValue) in protoFields(payload) {
                    guard inner == 1, case .bytes(let key) = innerValue, !key.isEmpty else { continue }
                    fromKey = extensionID(publicKey: key)
                }
            }
        }
        return fromKey
    }

    private enum ProtoValue {
        case bytes(Data)
        case other
    }

    private static func protoFields(_ data: Data) -> [(Int, ProtoValue)] {
        var fields: [(Int, ProtoValue)] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let (key, afterKey) = varint(data, index) else { return fields }
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            index = afterKey
            switch wire {
            case 0:
                guard let (_, next) = varint(data, index) else { return fields }
                index = next
                fields.append((field, .other))
            case 1:
                guard data.distance(from: index, to: data.endIndex) >= 8 else { return fields }
                index = data.index(index, offsetBy: 8)
                fields.append((field, .other))
            case 2:
                guard let (length, next) = varint(data, index) else { return fields }
                let count = Int(length)
                guard count >= 0, data.distance(from: next, to: data.endIndex) >= count else { return fields }
                let end = data.index(next, offsetBy: count)
                fields.append((field, .bytes(Data(data[next..<end]))))
                index = end
            case 5:
                guard data.distance(from: index, to: data.endIndex) >= 4 else { return fields }
                index = data.index(index, offsetBy: 4)
                fields.append((field, .other))
            default:
                return fields
            }
        }
        return fields
    }

    private static func varint(_ data: Data, _ start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex, shift <= 63 {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
        }
        return nil
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        return UInt32(data[start])
            | (UInt32(data[data.index(start, offsetBy: 1)]) << 8)
            | (UInt32(data[data.index(start, offsetBy: 2)]) << 16)
            | (UInt32(data[data.index(start, offsetBy: 3)]) << 24)
    }
}
