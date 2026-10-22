import CloudKit
import Foundation

/// `CKRecord.encodeSystemFields` persisted per record in `sync-state.json`.
/// The next save is built on top of this shell so the server change tag is kept.
nonisolated enum RecordSystemFields {
    static func encode(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decode(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        return CKRecord(coder: coder)
    }
}
