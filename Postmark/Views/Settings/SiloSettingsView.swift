import SwiftUI

/// Silo inbound addresses. These are per-user tokens (`<token>@mail.silo.day`);
/// they live in Keychain, never in the repo or rules file. A debug build uses
/// the dev address; a release build uses production.
struct SiloSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var prodAddress = ""
    @State private var devAddress = ""
    @State private var savedMessage: String?

    private static let placeholders = ["REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS", "REPLACE_WITH_YOUR_Silo_DEV_INBOUND_ADDRESS"]

    var body: some View {
        Form {
            Section {
                LabeledContent("Production address") {
                    TextField("<token>@mail.silo.day", text: $prodAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                LabeledContent("Dev address") {
                    TextField("<token>@mail-dev.silocall.com", text: $devAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                HStack {
                    Button("Save addresses") { save() }
                    if let savedMessage {
                        Text(savedMessage).font(.system(size: 11)).foregroundStyle(savedMessage.hasPrefix("Saved") ? .green : .red)
                    }
                }
            } header: {
                Text("Inbound email")
            } footer: {
                Text("Forwarded call sheets and production docs are addressed to the Silo user's inbound address and filed by shoot date. A debug build always forwards to the dev address; release uses production.")
            }

            Section {
                LabeledContent("Effective address (this build)") {
                    Text(effectiveAddress.isEmpty ? "(not configured)" : effectiveAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(effectiveIsPlaceholder ? .red : .secondary)
                }
                if effectiveIsPlaceholder {
                    Text("The runtime guard refuses to forward to a placeholder. Configure both addresses above before enabling triage.")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var effectiveAddress: String {
        settingsStore.siloDevAddress() ?? settingsStore.siloAddress() ?? ""
    }

    private var effectiveIsPlaceholder: Bool {
        effectiveAddress.isEmpty || Self.placeholders.contains(effectiveAddress)
    }

    private func load() {
        prodAddress = settingsStore.siloAddress() ?? ""
        devAddress = settingsStore.siloDevAddress() ?? ""
    }

    private func save() {
        do {
            try settingsStore.setSiloAddress(prodAddress.trimmingCharacters(in: .whitespacesAndNewlines))
            try settingsStore.setSiloDevAddress(devAddress.trimmingCharacters(in: .whitespacesAndNewlines))
            savedMessage = "Saved to Keychain"
        } catch {
            savedMessage = error.localizedDescription
        }
    }
}