import SwiftUI

/// Silo inbound production delivery address. A single full email address on
/// `mail.silo.day` is stored in the Keychain — never in the repo or rules file.
struct SiloSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var deliveryAddress = ""
    @State private var savedMessage: String?

    private static let placeholder = "REPLACE_WITH_YOUR_Silo_INBOUND_ADDRESS"
    private static let addressRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9._%+-]+@mail\\.silo\\.day$",
        options: [.caseInsensitive]
    )

    var body: some View {
        Form {
            Section {
                LabeledContent("Delivery address") {
                    TextField("you@mail.silo.day", text: $deliveryAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                }
                HStack {
                    Button("Save address") { save() }
                    if let savedMessage {
                        Text(savedMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(savedMessage.hasPrefix("Saved") ? .green : .red)
                    }
                }
            } header: {
                Text("Inbound email")
            } footer: {
                Text("Attachments forwarded to Silo are addressed to this production inbound address. Any address on mail.silo.day is accepted; the full address is stored in the Keychain and never in the repo.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        deliveryAddress = settingsStore.siloAddress() ?? ""
    }

    private func save() {
        let trimmed = deliveryAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != Self.placeholder else {
            savedMessage = "That's a placeholder, not a real address"
            return
        }
        guard trimmed.isEmpty || Self.isValidAddress(trimmed) else {
            savedMessage = "Enter a full email address on @mail.silo.day (e.g. you@mail.silo.day)"
            return
        }
        do {
            if trimmed.isEmpty {
                settingsStore.deleteSiloAddress()
            } else {
                try settingsStore.setSiloAddress(trimmed)
            }
            savedMessage = "Saved — forwarded attachments will use \(trimmed.isEmpty ? "no address (forwards refused)" : trimmed)"
        } catch {
            savedMessage = error.localizedDescription
        }
    }

    private static func isValidAddress(_ address: String) -> Bool {
        let range = NSRange(address.startIndex..., in: address)
        return addressRegex.firstMatch(in: address, options: [], range: range) != nil
    }
}