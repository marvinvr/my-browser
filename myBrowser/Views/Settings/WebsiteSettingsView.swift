import SwiftUI

/// Settings → Websites. Notification decisions are per origin, per profile.
struct WebsiteSettingsView: View {
    @Environment(BrowserModel.self) private var model

    private var showProfile: Bool {
        model.library.profiles.values.filter { $0.deletedAt == nil }.count > 1
    }

    var body: some View {
        Form {
            Section {
                if model.notifications.store.listed.isEmpty {
                    Text("No websites have asked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.notifications.store.listed) { record in
                        notificationRow(record)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("If a site is allowed and notifications still do not appear, turn them on for myBrowser in System Settings.")
            }
        }
    }

    private func notificationRow(_ record: NotificationPermissionStore.Record) -> some View {
        LabeledContent {
            Picker("Notifications", selection: choice(for: record)) {
                ForEach(NotificationSiteChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("notification-choice-\(record.host)")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.host)
                if showProfile, let name = model.library.profile(record.profileID)?.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func choice(for record: NotificationPermissionStore.Record) -> Binding<NotificationSiteChoice> {
        Binding(
            get: { model.notifications.siteChoice(profileID: record.profileID, origin: record.origin) },
            set: { model.notifications.setSiteChoice(profileID: record.profileID, origin: record.origin, choice: $0) }
        )
    }
}
