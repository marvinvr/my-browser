import AppKit
import SwiftUI

/// Glass command bar over the window. Shown while `commandBarMode` is set. Does not dim the page.
struct CommandBarOverlay: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        ZStack {
            if let mode = browser.commandBarMode {
                CommandBarPresenter(bar: CommandBarModel(browser: browser, mode: mode))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: browser.commandBarMode)
        .allowsHitTesting(browser.commandBarMode != nil)
    }
}

private struct CommandBarPresenter: View {
    @Environment(BrowserModel.self) private var browser
    @State private var bar: CommandBarModel

    init(bar: CommandBarModel) {
        _bar = State(initialValue: bar)
    }

    var body: some View {
        GeometryReader { geo in
            let top = max(88, geo.size.height * 0.16)
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { browser.hideCommandBar() }

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: top)
                        .allowsHitTesting(false)
                    CommandBarPanel(bar: bar)
                        .frame(width: min(620, max(280, geo.size.width - 48)))
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: browser.commandBarMode) { _, mode in
            guard let mode else { return }
            bar = CommandBarModel(browser: browser, mode: mode, engine: bar.engine)
        }
    }
}

private struct CommandBarPanel: View {
    @Environment(BrowserModel.self) private var browser
    @Bindable var bar: CommandBarModel

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            CommandBarTextField(
                text: $bar.query,
                placeholder: "Search or enter address",
                selectsAll: bar.mode == .editCurrent,
                onSubmit: { bar.execute() },
                onMove: { bar.moveSelection($0) },
                onCancel: { browser.hideCommandBar() }
            )
            .id(ObjectIdentifier(bar))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !bar.rows.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                    .opacity(0.45)
                VStack(spacing: 2) {
                    ForEach(Array(bar.rows.enumerated()), id: \.element.id) { index, row in
                        rowButton(row, selected: index == bar.selection)
                    }
                }
                .padding(6)
                .animation(.easeOut(duration: 0.12), value: bar.selection)
            }
        }
        .glassEffect(.regular, in: shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
    }

    private func rowButton(_ row: CommandBarModel.Row, selected: Bool) -> some View {
        Button {
            bar.execute(row)
        } label: {
            HStack(spacing: 10) {
                leadingIcon(row)
                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryText(row))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = subtitle(row) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if case .tab = row {
                    Text("Switch to Tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func leadingIcon(_ row: CommandBarModel.Row) -> some View {
        switch row {
        case .open:
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .search:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .tab(let item):
            if let image = browser.tabs[item.id]?.favicon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private func primaryText(_ row: CommandBarModel.Row) -> String {
        switch row {
        case .open(let title, _), .search(let title, _):
            title
        case .tab(let item):
            item.title.isEmpty ? (item.url?.absoluteString ?? "Tab") : item.title
        }
    }

    private func subtitle(_ row: CommandBarModel.Row) -> String? {
        guard case .tab(let item) = row else { return nil }
        guard !item.title.isEmpty, let absolute = item.url?.absoluteString else { return nil }
        return absolute
    }
}
