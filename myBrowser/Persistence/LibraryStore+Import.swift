import Foundation

extension LibraryStore {
    /// Inserts `plan` in one change batch, so listeners fire once and the file saves once.
    /// Pass `existingSpaceID` to append every space's items into that space.
    @discardableResult
    func apply(_ plan: ImportPlan, to existingSpaceID: UUID? = nil) -> ImportResult {
        if let existingSpaceID {
            guard space(existingSpaceID) != nil else { return .empty }
            var result = ImportResult.empty
            result.spaceIDs = [existingSpaceID]
            result.notes = plan.notes
            performBatch {
                for imported in plan.spaces {
                    add(imported, to: existingSpaceID, result: &result)
                }
            }
            return result.favoriteCount + result.pinnedCount + result.tabCount == 0 && plan.spaces.isEmpty
                ? .empty
                : result
        }

        var result = ImportResult.empty
        result.notes = plan.notes
        performBatch {
            var profileIDs: [String: UUID] = [:]
            for imported in plan.profiles {
                let profile = Profile(name: imported.name)
                profiles[profile.id] = profile
                profileIDs[imported.key] = profile.id
                didChange([profile.id])
                result.profilesCreated += 1
            }
            for imported in plan.spaces {
                let profileID = profileIDs[imported.profileKey] ?? {
                    let profile = Profile(name: imported.name)
                    profiles[profile.id] = profile
                    profileIDs[imported.profileKey] = profile.id
                    didChange([profile.id])
                    result.profilesCreated += 1
                    return profile.id
                }()
                let space = Space(
                    name: imported.name,
                    symbol: imported.symbol.isEmpty ? "circle.fill" : imported.symbol,
                    emoji: imported.emoji.flatMap { $0.isEmpty ? nil : $0 },
                    color: imported.color,
                    profileID: profileID,
                    sortKey: SortKey.between(orderedSpaces.last?.sortKey, nil)
                )
                spaces[space.id] = space
                didChange([space.id])
                result.spacesCreated += 1
                result.spaceIDs.append(space.id)
                add(imported, to: space.id, result: &result)
            }
        }
        return result
    }

    private func add(_ imported: ImportPlan.Space, to spaceID: UUID, result: inout ImportResult) {
        result.favoriteCount += insert(imported.favorites, spaceID: spaceID, section: .favorites, parentID: nil)
        result.pinnedCount += insert(imported.pinned, spaceID: spaceID, section: .pinned, parentID: nil)
        result.tabCount += insert(imported.tabs, spaceID: spaceID, section: .tabs, parentID: nil)
    }

    @discardableResult
    private func insert(
        _ nodes: [ImportNode],
        spaceID: UUID,
        section: SidebarItem.Section,
        parentID: UUID?
    ) -> Int {
        var count = 0
        for node in nodes {
            switch node {
            case .folder(let title, let children):
                guard section == .pinned else {
                    count += insert(children, spaceID: spaceID, section: section, parentID: nil)
                    continue
                }
                let folder = addItem(
                    spaceID: spaceID,
                    section: .pinned,
                    kind: .folder,
                    parentID: parentID,
                    title: title,
                    at: .end
                )
                count += 1
                count += insert(children, spaceID: spaceID, section: .pinned, parentID: folder.id)
            case .site(let title, let url):
                addItem(
                    spaceID: spaceID,
                    section: section,
                    kind: .site,
                    parentID: section == .pinned ? parentID : nil,
                    title: title,
                    url: url,
                    at: .end
                )
                count += 1
            }
        }
        return count
    }
}
