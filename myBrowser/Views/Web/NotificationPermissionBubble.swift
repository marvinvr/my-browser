import AppKit
import SwiftUI

/// Address-bar prompt. Outside dismissal does not decide; Allow and Don't Allow do.
struct NotificationPermissionBubble: View {
    var host: String
    var onAllow: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(host) wants to send notifications")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Don't Allow", action: onDeny)
                    .accessibilityIdentifier("notification-deny")
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("notification-allow")
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notification-permission")
    }
}
