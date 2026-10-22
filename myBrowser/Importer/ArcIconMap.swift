import Foundation

/// Arc space icons are emoji or a short name. Names become the closest SF Symbol.
nonisolated enum ArcIconMap {
    static func symbol(for name: String) -> String {
        if name.contains(".") { return name }
        return symbols[name.lowercased()] ?? "circle.fill"
    }

    static func symbol(forEmoji emoji: String) -> String {
        let key = String(emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map(Character.init))
        return emojiSymbols[key] ?? "circle.fill"
    }

    private static let symbols: [String: String] = [
        "book": "book.fill",
        "bookmark": "bookmark.fill",
        "briefcase": "briefcase.fill",
        "calendar": "calendar",
        "cloud": "cloud.fill",
        "code": "chevron.left.forwardslash.chevron.right",
        "flash": "bolt.fill",
        "folder": "folder.fill",
        "game": "gamecontroller.fill",
        "github": "link",
        "globe": "globe",
        "heart": "heart.fill",
        "home": "house.fill",
        "house": "house.fill",
        "mail": "envelope.fill",
        "music": "music.note",
        "person": "person.fill",
        "star": "star.fill",
        "video": "play.rectangle.fill",
        "work": "briefcase.fill",
    ]

    private static let emojiSymbols: [String: String] = [
        "🏠": "house.fill",
        "📚": "book.fill",
        "💼": "briefcase.fill",
        "🎨": "paintbrush.fill",
        "⭐": "star.fill",
        "❤️": "heart.fill",
        "💻": "laptopcomputer",
        "🌐": "globe",
    ]
}
