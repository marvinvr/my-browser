import AppKit

extension BrowserModel {
    func togglePictureInPicture(_ itemID: UUID? = nil) {
        let id = itemID ?? selectedItemID
        guard let id, let tab = tabs[id], tab.showsPictureInPictureButton else { return }
        let active = tab.isPictureInPictureActive || pictureInPictureSession?.tabID == id
        let (session, effects) = PictureInPicturePolicy.toggle(
            session: pictureInPictureSession,
            tabID: id,
            isActive: active
        )
        applyPictureInPicture(session: session, effects: effects)
    }

    func installPictureInPictureMonitoring() {
        guard pictureInPictureObservers.isEmpty else { return }
        // App deactivation pauses media if we wait. Enter synchronously inside will-resign,
        // while `hasPictureInPictureVideo` is still true. `isActive` is often still true here.
        let leaving = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self?.applyPictureInPictureFocus(force: false, leaving: true)
            }
        }
        pictureInPictureObservers.append(leaving)
        // Become-active has to exit on the posting thread. A later hop loses to the PiP
        // panel, which activates itself again and makes the app look unfocused.
        let returning = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self?.applyPictureInPictureFocus(force: false)
            }
        }
        pictureInPictureObservers.append(returning)
        // Same-app focus loss (another window becomes key) does not pause the video.
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.schedulePictureInPictureFocusCheck()
                }
            }
            pictureInPictureObservers.append(token)
        }
    }

    func syncPictureInPictureForeground() {
        let nowID = selectedTab?.id
        let previousID = pictureInPictureForegroundID
        guard previousID != nowID else { return }
        let previous = previousID.flatMap { tabs[$0] }
        let canEnter = pictureInPictureCanEnter(previous)
        let (session, effects) = PictureInPicturePolicy.selection(
            autoEnabled: PictureInPictureSettings.autoEnabled,
            session: pictureInPictureSession,
            from: previousID,
            fromCanEnter: canEnter,
            to: nowID
        )
        pictureInPictureForegroundID = nowID
        applyPictureInPicture(session: session, effects: effects)
    }

    func endPictureInPicture(for id: UUID) {
        guard pictureInPictureSession?.tabID == id || pictureInPictureTabID == id else { return }
        tabs[id]?.exitPictureInPicture()
        pictureInPictureSession = nil
        pictureInPictureTabID = nil
        pictureInPictureEnterGeneration += 1
    }

    func ingestPictureInPicture(_ tab: BrowserTab) {
        if tab.isPictureInPictureActive {
            let session = PictureInPicturePolicy.pageEntered(session: pictureInPictureSession, tabID: tab.id)
            pictureInPictureSession = session
            if pictureInPictureTabID != session.tabID {
                pictureInPictureTabID = session.tabID
            }
        } else if pictureInPictureSession?.tabID == tab.id {
            let requested = tab.consumePictureInPictureReturnSuppression()
            let (session, effects) = PictureInPicturePolicy.ended(
                session: pictureInPictureSession,
                tabID: tab.id,
                requestedByUs: requested
            )
            applyPictureInPicture(session: session, effects: effects)
        }
        if tab.id == selectedItemID {
            refreshNavigationState()
        }
    }

    func pictureInPictureContainer() -> NSView? {
        if let host = selectedTab?.webView?.superview { return host }
        if let host = tabs.values.compactMap({ $0.webView?.superview }).first { return host }
        return browserWindowForPictureInPicture()?.contentView
    }

    private func applyPictureInPicture(session: PictureInPictureSession?, effects: [PictureInPictureEffect]) {
        pictureInPictureSession = session
        if pictureInPictureTabID != session?.tabID {
            pictureInPictureTabID = session?.tabID
        }
        for effect in effects {
            switch effect {
            case .enter(let id, _):
                pictureInPictureIgnoreFocusUntil = Date().addingTimeInterval(0.8)
                tabs[id]?.loadIfNeeded(using: profiles)
                tabs[id]?.enterPictureInPicture()
                armPictureInPictureTimeout(id)
            case .exit(let id):
                tabs[id]?.exitPictureInPicture()
            case .focus(let id):
                revealPictureInPictureTab(id)
            }
        }
    }

    private func revealPictureInPictureTab(_ id: UUID) {
        guard let item = library.item(id) else { return }
        let already = selectedItemID == id && selectedSpaceID == item.spaceID
        if !already {
            select(id)
        }
        NSApp.activate(ignoringOtherApps: true)
        browserWindowForPictureInPicture()?.makeKeyAndOrderFront(nil)
    }

    private func armPictureInPictureTimeout(_ id: UUID) {
        pictureInPictureEnterGeneration += 1
        let generation = pictureInPictureEnterGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, generation == self.pictureInPictureEnterGeneration else { return }
            guard self.pictureInPictureSession?.tabID == id else { return }
            guard self.tabs[id]?.isPictureInPictureActive != true else { return }
            self.pictureInPictureSession = nil
            self.pictureInPictureTabID = nil
        }
    }

    private func schedulePictureInPictureFocusCheck() {
        pictureInPictureFocusTask?.cancel()
        pictureInPictureFocusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.applyPictureInPictureFocus(force: false)
        }
    }

    private func applyPictureInPictureFocus(force: Bool, leaving: Bool = false) {
        if !force, Date() < pictureInPictureIgnoreFocusUntil { return }
        guard browserWindowForPictureInPicture() != nil else { return }
        // The system PiP panel is another process and often keeps key, so "back in the app"
        // is NSApp.isActive, not isKeyWindow. `leaving` covers willResignActive, where
        // isActive is still true.
        let focused = !leaving && NSApp.isActive
        guard focused != pictureInPictureWindowFocused || force else { return }
        pictureInPictureWindowFocused = focused
        let tab = selectedTab
        let canEnter = pictureInPictureCanEnter(tab)
        let (session, effects) = PictureInPicturePolicy.focus(
            autoEnabled: PictureInPictureSettings.autoEnabled,
            session: pictureInPictureSession,
            windowFocused: focused,
            selectedTab: tab?.id,
            selectedCanEnter: canEnter
        )
        guard session != pictureInPictureSession || !effects.isEmpty else { return }
        applyPictureInPicture(session: session, effects: effects)
    }

    private func pictureInPictureCanEnter(_ tab: BrowserTab?) -> Bool {
        guard let tab, !tab.isPictureInPictureActive else { return false }
        if tab.hasPictureInPictureVideo { return true }
        return Date() < tab.pictureInPictureEligibleUntil
    }
}
