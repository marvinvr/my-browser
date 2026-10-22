import CloudKit
import Foundation

/// Private-database zone and record names for the library.
/// Record names are the model UUIDs (`CKRecord.ID(recordName:zoneID:)`).
nonisolated enum SyncSchema {
    static let zoneName = "Library"
    static let containerIdentifier = "iCloud.ch.marvinvr.mybrowser"

    enum RecordType {
        static let profile = "Profile"
        static let space = "Space"
        static let sidebarItem = "SidebarItem"
    }

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName)
    }

    static var zone: CKRecordZone {
        CKRecordZone(zoneID: zoneID)
    }

    static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }
}
