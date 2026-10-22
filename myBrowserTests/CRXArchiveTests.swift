import Foundation
import Testing
@testable import myBrowser

struct CRXArchiveTests {
    @Test func version2StripsTheHeaderAndHashesTheKey() throws {
        let key = Data([0x2b, 0x10, 0xff, 0x01])
        let signature = Data([0xaa, 0xbb])
        let zip = Data("PKFAKE".utf8)
        var data = Data("Cr24".utf8)
        data.append(le(2))
        data.append(le(UInt32(key.count)))
        data.append(le(UInt32(signature.count)))
        data.append(key)
        data.append(signature)
        data.append(zip)

        let payload = try CRXArchive.payload(from: data)
        #expect(payload.version == 2)
        #expect(payload.zip == zip)
        #expect(payload.extensionID == CRXArchive.extensionID(publicKey: key))
    }

    @Test func version3PrefersTheSignedCrxID() throws {
        let crxID = Data(repeating: 0, count: 16)
        let header = protoLengthField(field: 10_000, payload: protoLengthField(field: 1, payload: crxID))
        let zip = Data("PKZIP".utf8)
        var data = Data("Cr24".utf8)
        data.append(le(3))
        data.append(le(UInt32(header.count)))
        data.append(header)
        data.append(zip)

        let payload = try CRXArchive.payload(from: data)
        #expect(payload.version == 3)
        #expect(payload.zip == zip)
        #expect(payload.extensionID == String(repeating: "a", count: 32))
    }

    @Test func rejectsABadMagicTruncationAndAnUnknownVersion() {
        #expect(throws: CRXArchive.Failure.notCRX) {
            try CRXArchive.payload(from: Data("XXXX________".utf8))
        }
        #expect(throws: CRXArchive.Failure.truncated) {
            try CRXArchive.payload(from: Data("Cr24".utf8))
        }
        var unknown = Data("Cr24".utf8)
        unknown.append(le(9))
        unknown.append(Data(repeating: 0, count: 16))
        #expect(throws: CRXArchive.Failure.unsupportedVersion(9)) {
            try CRXArchive.payload(from: unknown)
        }
    }

    @Test func nibbleEncodingMapsZeroToAAndTheHighNibbleFirst() {
        #expect(CRXArchive.encodeID(Data(repeating: 0, count: 16)) == String(repeating: "a", count: 32))
        #expect(CRXArchive.encodeID(Data([0x2b])).hasPrefix("cl"))
        #expect(CRXArchive.extensionID(crxID: Data(repeating: 1, count: 15)) == nil)
    }

    private func le(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    /// Protobuf length-delimited field. Field numbers here stay under 2^14 so the key is at most three varint bytes.
    private func protoLengthField(field: Int, payload: Data) -> Data {
        var key = (field << 3) | 2
        var encoded = Data()
        while true {
            let byte = UInt8(key & 0x7f)
            key >>= 7
            if key == 0 {
                encoded.append(byte)
                break
            }
            encoded.append(byte | 0x80)
        }
        var length = payload.count
        while true {
            let byte = UInt8(length & 0x7f)
            length >>= 7
            if length == 0 {
                encoded.append(byte)
                break
            }
            encoded.append(byte | 0x80)
        }
        encoded.append(payload)
        return encoded
    }
}
