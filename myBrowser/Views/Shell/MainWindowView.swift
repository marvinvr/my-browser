import SwiftUI

struct MainWindowView: View {
    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 240)
            WebContentView()
        }
        .ignoresSafeArea(edges: .top)
        .background(WindowConfigurator())
        .overlay { CommandBarOverlay() }
    }
}
