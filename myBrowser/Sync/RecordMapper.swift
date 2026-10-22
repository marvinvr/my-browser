import CloudKit
import Foundation

/// A library value read back from a `CKRecord`. `.tabs` items are never produced.
nonisolated enum MappedRecord: Equatable, Sendable {
    case profile(Profile)
    case space(Space)
    case item(SidebarItem)
}

/// Profile / Space / SidebarItem ⇄ `CKRecord` fields. No network.
nonisolated enum RecordMapper {
    enum Field {
        static let name = "name"
        static let modifiedAt = "modifiedAt"
        static let deletedAt = "deletedAt"
        static let symbol = "symbol"
        static let color = "color"
        static let profileID = "profileID"
        static let sortKey = "sortKey"
        static let spaceID = "spaceID"
        static let section = "section"
        static let kind = "kind"
        static let parentID = "parentID"
        static let title = "title"
        static let url = "url"
        static let isExpanded = "isExpanded"
        static let createdAt = "createdAt"
    }

    static func record(for profile: Profile, systemFields: Data? = nil) -> CKRecord {
        let record = baseRecord(type: SyncSchema.RecordType.profile, id: profile.id, systemFields: systemFields)
        set(record, Field.name, profile.name)
        set(record, Field.modifiedAt, profile.modifiedAt)
        set(record, Field.deletedAt, profile.deletedAt)
        return record
    }

    static func record(for space: Space, systemFields: Data? = nil) -> CKRecord {
        let record = baseRecord(type: SyncSchema.RecordType.space, id: space.id, systemFields: systemFields)
        set(record, Field.name, space.name)
        set(record, Field.symbol, space.symbol)
        set(record, Field.color, space.color.rawValue)
        set(record, Field.profileID, space.profileID.uuidString)
        set(record, Field.sortKey, space.sortKey)
        set(record, Field.modifiedAt, space.modifiedAt)
        set(record, Field.deletedAt, space.deletedAt)
        return record
    }

    /// Nil for `.tabs` items. Those rows stay on device.
    static func record(for item: SidebarItem, systemFields: Data? = nil) -> CKRecord? {
        guard item.section != .tabs else { return nil }
        let record = baseRecord(type: SyncSchema.RecordType.sidebarItem, id: item.id, systemFields: systemFields)
        set(record, Field.spaceID, item.spaceID.uuidString)
        set(record, Field.section, item.section.rawValue)
        set(record, Field.kind, item.kind.rawValue)
        set(record, Field.parentID, item.parentID?.uuidString)
        set(record, Field.title, item.title)
        set(record, Field.url, item.url?.absoluteString)
        set(record, Field.sortKey, item.sortKey)
        set(record, Field.isExpanded, item.isExpanded ? 1 : 0)
        set(record, Field.createdAt, item.createdAt)
        set(record, Field.modifiedAt, item.modifiedAt)
        set(record, Field.deletedAt, item.deletedAt)
        return record
    }

    static func decode(_ record: CKRecord) -> MappedRecord? {
        switch record.recordType {
        case SyncSchema.RecordType.profile:
            return profile(from: record).map(MappedRecord.profile)
        case SyncSchema.RecordType.space:
            return space(from: record).map(MappedRecord.space)
        case SyncSchema.RecordType.sidebarItem:
            return item(from: record).map(MappedRecord.item)
        default:
            return nil
        }
    }

    static func profile(from record: CKRecord) -> Profile? {
        guard record.recordType == SyncSchema.RecordType.profile,
              let id = uuid(record),
              let name = string(record, Field.name),
              let modifiedAt = date(record, Field.modifiedAt) else { return nil }
        var profile = Profile(id: id, name: name, modifiedAt: modifiedAt)
        profile.deletedAt = date(record, Field.deletedAt)
        return profile
    }

    static func space(from record: CKRecord) -> Space? {
        guard record.recordType == SyncSchema.RecordType.space,
              let id = uuid(record),
              let name = string(record, Field.name),
              let symbol = string(record, Field.symbol),
              let colorRaw = string(record, Field.color),
              let color = SpaceColor(rawValue: colorRaw),
              let profileID = uuidString(record, Field.profileID),
              let sortKey = string(record, Field.sortKey),
              let modifiedAt = date(record, Field.modifiedAt) else { return nil }
        var space = Space(
            id: id,
            name: name,
            symbol: symbol,
            color: color,
            profileID: profileID,
            sortKey: sortKey,
            modifiedAt: modifiedAt
        )
        space.deletedAt = date(record, Field.deletedAt)
        return space
    }

    static func item(from record: CKRecord) -> SidebarItem? {
        guard record.recordType == SyncSchema.RecordType.sidebarItem,
              let id = uuid(record),
              let spaceID = uuidString(record, Field.spaceID),
              let sectionRaw = string(record, Field.section),
              let section = SidebarItem.Section(rawValue: sectionRaw),
              section != .tabs,
              let kindRaw = string(record, Field.kind),
              let kind = SidebarItem.Kind(rawValue: kindRaw),
              let title = string(record, Field.title),
              let sortKey = string(record, Field.sortKey),
              let createdAt = date(record, Field.createdAt),
              let modifiedAt = date(record, Field.modifiedAt) else { return nil }
        var item = SidebarItem(
            id: id,
            spaceID: spaceID,
            section: section,
            kind: kind,
            parentID: uuidString(record, Field.parentID),
            title: title,
            url: string(record, Field.url).flatMap(URL.init(string:)),
            sortKey: sortKey,
            isExpanded: bool(record, Field.isExpanded, default: true),
            createdAt: createdAt
        )
        item.modifiedAt = modifiedAt
        item.deletedAt = date(record, Field.deletedAt)
        return item
    }

    static func side(of record: CKRecord) -> SyncConflict.Side? {
        guard let modifiedAt = date(record, Field.modifiedAt) else { return nil }
        return SyncConflict.Side(modifiedAt: modifiedAt, deletedAt: date(record, Field.deletedAt))
    }

    private static func baseRecord(type: String, id: UUID, systemFields: Data?) -> CKRecord {
        let recordID = SyncSchema.recordID(for: id)
        if let systemFields,
           let shell = RecordSystemFields.decode(systemFields),
           shell.recordType == type,
           shell.recordID.recordName == id.uuidString {
            return shell
        }
        return CKRecord(recordType: type, recordID: recordID)
    }

    private static func set(_ record: CKRecord, _ key: String, _ value: (any CKRecordValueProtocol)?) {
        record[key] = value
    }

    private static func uuid(_ record: CKRecord) -> UUID? {
        UUID(uuidString: record.recordID.recordName)
    }

    private static func string(_ record: CKRecord, _ key: String) -> String? {
        record[key] as? String
    }

    private static func uuidString(_ record: CKRecord, _ key: String) -> UUID? {
        (record[key] as? String).flatMap(UUID.init(uuidString:))
    }

    private static func date(_ record: CKRecord, _ key: String) -> Date? {
        record[key] as? Date
    }

    private static func bool(_ record: CKRecord, _ key: String, default defaultValue: Bool) -> Bool {
        switch record[key] {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.intValue != 0
        default:
            return defaultValue
        }
    }
}
