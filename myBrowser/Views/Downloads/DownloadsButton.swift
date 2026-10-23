import SwiftUI

/// `arrow.down.circle` at the trailing end of the toolbar.
/// Visible while this profile has an active download, or a recent one that has not been cleared.
/// A ring around the symbol tracks bytes. An unknown size draws a moving arc instead.
struct DownloadsToolbarButton: View {
    var symbol: Color

    @Environment(BrowserModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        let visible = downloads.toolbarVisible
        DownloadsToolbarButtonBody(symbol: symbol, downloads: downloads)
            .frame(width: visible ? SidebarMetrics.toolbarControl : 0, height: SidebarMetrics.toolbarControl)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(.spring(duration: 0.28, bounce: 0), value: visible)
    }
}

private struct DownloadsToolbarButtonBody: View {
    var symbol: Color
    @Bindable var downloads: DownloadManager

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            downloads.isPopoverPresented.toggle()
        } label: {
            ZStack {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                if downloads.isDownloading {
                    DownloadProgressRing(fraction: downloads.ringFraction, color: symbol)
                }
            }
            .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
            .background {
                Circle().fill(symbol.opacity(hovering ? 0.16 : 0))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(symbol)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .popover(isPresented: $downloads.isPopoverPresented, arrowEdge: .bottom) {
            DownloadsPopover()
                .environment(model)
        }
    }
}

/// Neutral ring. The track and the arc use the toolbar symbol colour, not the accent.
private struct DownloadProgressRing: View {
    var fraction: Double?
    var color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: 1.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.03), 1))
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 200))
                }
            }
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}
