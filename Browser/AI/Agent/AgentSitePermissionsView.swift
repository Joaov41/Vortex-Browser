import SwiftUI

struct AgentSitePermissionsView: View {
    @ObservedObject private var store: AgentTrustStore

    init(store: AgentTrustStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? AgentTrustStore.shared)
    }

    var body: some View {
        List {
            if store.permissions.isEmpty {
                ContentUnavailableView(
                    "No Site Permissions",
                    systemImage: "hand.raised",
                    description: Text("Choose “Always on site” on an eligible agent approval to add an exact host and action reason.")
                )
            } else {
                Section {
                    ForEach(store.permissions) { permission in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.host)
                                .font(.body.weight(.semibold))
                                .textSelection(.enabled)
                            Text("Always allow: \(permission.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.revoke(permission)
                            } label: {
                                Label("Revoke", systemImage: "hand.raised.slash")
                            }
                        }
                    }
                } footer: {
                    Text("Permissions apply only to the exact host and action reason shown. Private browsing never reads or saves them.")
                }
            }
        }
        .navigationTitle("Agent Site Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
