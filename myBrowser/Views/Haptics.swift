import AppKit

/// Trackpad haptics. Retune a moment here; call sites only name it.
/// Each call is one pulse. Callers fire on a state change, never on a repeated sample.
enum Haptics {
    enum Moment: Equatable {
        /// Sidebar column locks onto the next or previous Space.
        case spaceSnap
        /// Page swipe crosses the distance where releasing will navigate.
        case navigationThreshold
        /// Dragged row locks into a different drop slot.
        case dropSlot
        /// Drag crosses between Tabs and Pinned.
        case pinChange
        /// A hovered folder opens on its own.
        case folderExpand
        /// A Space icon becomes the drop target.
        case spaceTarget
        /// The drop lands.
        case drop
    }

    static func play(_ moment: Moment) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        let time: NSHapticFeedbackManager.PerformanceTime
        switch moment {
        case .spaceSnap:
            pattern = .alignment
            time = .now
        case .navigationThreshold:
            pattern = .levelChange
            time = .now
        case .dropSlot:
            pattern = .alignment
            time = .drawCompleted
        case .pinChange:
            pattern = .levelChange
            time = .now
        case .folderExpand:
            pattern = .generic
            time = .drawCompleted
        case .spaceTarget:
            pattern = .alignment
            time = .now
        case .drop:
            pattern = .generic
            time = .drawCompleted
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: time)
    }
}

/// Remembers the last token. A repeat is silent. Clearing to nil is silent and arms the next value.
struct HapticGate<Token: Equatable>: Equatable {
    private(set) var token: Token?

    /// The new token when it changed to a non-nil value.
    mutating func changed(to next: Token?) -> Token? {
        guard next != token else { return nil }
        token = next
        return next
    }

    mutating func reset() {
        token = nil
    }
}

enum NavigationSwipeDirection: Equatable {
    case back
    case forward
}

/// One reading of WebKit's swipe layers. `progress` is 0 at rest and 1 at a full page.
struct NavigationSwipeSample: Equatable {
    var swipeRootTranslation: CGFloat?
    var liveTranslation: CGFloat?
    var width: CGFloat
}

struct NavigationSwipeReading: Equatable {
    var progress: CGFloat
    var direction: NavigationSwipeDirection?
    var hasSwipeLayer: Bool

    /// WebKit commits a swipe at `min(187.5pt, half the page)`.
    /// See `SwipeProgressTracker::shouldCancel`.
    static func thresholdFraction(width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0.5 }
        return min(187.5 / width, 0.5)
    }

    static func read(_ sample: NavigationSwipeSample) -> NavigationSwipeReading {
        guard let root = sample.swipeRootTranslation, sample.width > 1 else {
            return NavigationSwipeReading(progress: 0, direction: nil, hasSwipeLayer: false)
        }
        let width = sample.width
        // Back: the snapshot layer starts about one page over and slides toward zero.
        if root > width * 0.45 {
            let progress = min(max((width - root) / width, 0), 1)
            return NavigationSwipeReading(progress: progress, direction: .back, hasSwipeLayer: true)
        }
        // Forward: that layer stays put and the page layer slides.
        guard let live = sample.liveTranslation, abs(live) > 0.5 else {
            return NavigationSwipeReading(progress: 0, direction: nil, hasSwipeLayer: true)
        }
        let progress = min(abs(live) / width, 1)
        let direction: NavigationSwipeDirection = live > 0 ? .forward : .back
        return NavigationSwipeReading(progress: progress, direction: direction, hasSwipeLayer: true)
    }
}

/// One pulse when the page swipe crosses WebKit's completion distance, again only after a retreat.
struct NavigationSwipeDetent: Equatable {
    /// Progress has to fall back under this fraction of the line before the next crossing counts.
    static let retreatFactor: CGFloat = 0.7

    private var gate = HapticGate<NavigationSwipeDirection>()

    mutating func update(
        progress: CGFloat,
        direction: NavigationSwipeDirection?,
        width: CGFloat,
        canGoBack: Bool,
        canGoForward: Bool
    ) -> Bool {
        let line = NavigationSwipeReading.thresholdFraction(width: width)
        let allowed: NavigationSwipeDirection? = switch direction {
        case .back where canGoBack: .back
        case .forward where canGoForward: .forward
        default: nil
        }
        if let allowed, progress >= line {
            return gate.changed(to: allowed) != nil
        }
        if progress < line * Self.retreatFactor {
            _ = gate.changed(to: nil)
        }
        return false
    }

    mutating func reset() {
        gate.reset()
    }
}

/// Which drag change deserves a pulse. Folder hover is silent; the expand is a separate moment.
struct SidebarDragHaptics: Equatable {
    private enum Token: Equatable {
        case slot(space: UUID, section: SidebarItem.Section, parent: UUID?, position: SidebarDropPosition)
        case space(UUID)
        case split(UUID)
    }

    private var gate = HapticGate<Token>()
    private var section: SidebarItem.Section?

    mutating func note(_ proposal: SidebarDropProposal?) -> Haptics.Moment? {
        guard let token = Self.token(for: proposal) else { return nil }
        guard gate.changed(to: token) != nil else { return nil }
        switch token {
        case .slot(_, let section, _, _):
            let crossed = Self.isPinCrossing(from: self.section, to: section)
            self.section = section
            return crossed ? .pinChange : .dropSlot
        case .space:
            self.section = nil
            return .spaceTarget
        case .split:
            return .dropSlot
        }
    }

    /// The drag ended. The next drag may land on the same slot and should tick again.
    mutating func reset() {
        gate.reset()
        section = nil
    }

    private static func token(for proposal: SidebarDropProposal?) -> Token? {
        switch proposal {
        case .insert(let insertion):
            .slot(space: insertion.spaceID, section: insertion.section, parent: insertion.parentID, position: insertion.position)
        case .ontoSpace(let id):
            .space(id)
        case .intoSplit(let id):
            .split(id)
        case .intoFolder, nil:
            nil
        }
    }

    private static func isPinCrossing(from previous: SidebarItem.Section?, to section: SidebarItem.Section) -> Bool {
        guard let previous, previous != section else { return false }
        return (previous == .tabs || previous == .pinned) && (section == .tabs || section == .pinned)
    }
}
