import Foundation

extension BrowserModel {
    /// Reloads open web pages in this profile so a newly enabled extension's content scripts run.
    func reloadWebTabs(in profileID: UUID) {
        for tab in tabs.values where tab.profileID == profileID {
            guard let scheme = tab.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            tab.reload()
        }
    }

    /// Opens a tab for an extension and returns the live tab. `active` selects it.
    @discardableResult
    func openTabForExtension(url: URL?, active: Bool, parent: BrowserTab? = nil) -> BrowserTab? {
        guard library.space(selectedSpaceID) != nil else { return nil }
        let pageURL = url.flatMap { BrowserTab.isPageURL($0) ? $0 : nil }
        let title = pageURL.map { Self.fallbackTitle(for: $0) } ?? "New Tab"
        let item = library.addItem(
            spaceID: selectedSpaceID,
            section: .tabs,
            kind: .site,
            title: title,
            url: pageURL,
            at: .start
        )
        let tab = ensureTab(for: item)
        tab.extensionBridge.parentTab = parent
        let created = !tab.isLoaded
        tab.loadIfNeeded(using: profiles)
        if created {
            extensions?.tabOpened(tab)
        }
        if active {
            select(item.id)
        }
        return tab
    }

    func connectExtension(_ tab: BrowserTab, spaceID: UUID) {
        tab.extensionBridge.spaceID = spaceID
        tab.extensionBridge.window = { [weak self] in self?.extensions?.window }
        tab.extensionBridge.isSelected = { [weak self, weak tab] in
            guard let tab else { return false }
            return self?.selectedTab?.id == tab.id
        }
        tab.extensionBridge.index = { [weak self, weak tab] in
            guard let self, let tab else { return NSNotFound }
            let items = self.navigableItems(in: spaceID).filter { $0.kind == .site }
            return items.firstIndex { $0.id == tab.id } ?? NSNotFound
        }
        tab.extensionBridge.isPinned = { [weak self, weak tab] in
            guard let tab, let section = self?.library.item(tab.id)?.section else { return false }
            return section != .tabs
        }
        tab.extensionBridge.activate = { [weak self, weak tab] in
            guard let tab else { return }
            self?.select(tab.id)
        }
        tab.extensionBridge.close = { [weak self, weak tab] in
            guard let tab else { return }
            self?.close(tab.id)
        }
        tab.extensionBridge.setPinned = { [weak self, weak tab] pinned in
            guard let tab else { return }
            if pinned {
                self?.pin(tab.id)
            } else {
                self?.unpin(tab.id)
            }
        }
    }
}
