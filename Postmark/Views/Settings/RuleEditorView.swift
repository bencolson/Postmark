import SwiftUI

/// Edits `PostmarkRules.json` in memory and saves atomically: the two LLM prompts,
/// per-rule actions, and the forward target types. Changing the prompts here is
/// how you keep (or intentionally drift from) n8n parity.
struct RuleEditorView: View {
    @State private var rules: PostmarkRules?
    @State private var saveState: SaveState = .idle
    @State private var loadError: String?

    enum SaveState: Equatable { case idle, saved, failed(String) }

    private static let n8nOrder = ["low-priority", "lead", "receipt", "other"]

    var body: some View {
        ScrollView {
            if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
                Spacer()
            } else if let rules {
                VStack(alignment: .leading, spacing: 14) {
                    classifierSection(rules)
                    attachmentSection(rules)
                    rulesSection(rules)
                    forwardSection(rules)
                    saveBar
                }
                .padding(16)
            } else {
                ProgressView("Loading rules…").padding()
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Classifier prompt

    private func classifierSection(_ r: PostmarkRules) -> some View {
        SectionCard(title: "Message classifier prompt", subtitle: "Port of n8n's email-categorisation prompt. The model returns one of: \(r.rules.map(\.id).joined(separator: ", ")).") {
            TextEditor(text: Binding(
                get: { r.classifier.prompt },
                set: { rules?.classifier.prompt = $0 }
            ))
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: - Attachment prompt

    private func attachmentSection(_ r: PostmarkRules) -> some View {
        SectionCard(title: "Attachment classifier prompt", subtitle: "Port of n8n's Build Classification Prompt. Expects a JSON array of {filename, category, date}.") {
            TextEditor(text: Binding(
                get: { r.attachment.prompt },
                set: { rules?.attachment.prompt = $0 }
            ))
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 160)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: - Rules

    private func rulesSection(_ r: PostmarkRules) -> some View {
        SectionCard(title: "Rules", subtitle: "Action per category — move, mark read, leave, draft a reply, or forward.") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(r.rules.indices, id: \.self) { i in
                    ruleRow(r, index: i)
                }
                Divider().opacity(0.4)
                Text("Fallback (unmatched): \(r.fallback.action.leave == true ? "leave" : "leave")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ruleRow(_ r: PostmarkRules, index i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(r.rules[i].id)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Label", text: Binding(
                    get: { rules?.rules[i].label ?? "" },
                    set: { rules?.rules[i].label = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            }

            HStack(spacing: 14) {
                Toggle("Mark read", isOn: bindingFor(.markRead, index: i))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Toggle("Leave", isOn: bindingFor(.leave, index: i))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Mailbox to move to (blank = no move)", text: Binding(
                    get: { rules?.rules[i].action.move ?? "" },
                    set: { rules?.rules[i].action.move = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Toggle("Draft a reply (not sent)", isOn: bindingFor(.draftReply, index: i))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            if rules?.rules[i].action.draftReply == true {
                TextEditor(text: Binding(
                    get: { rules?.rules[i].action.draftPrompt ?? "" },
                    set: { rules?.rules[i].action.draftPrompt = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            HStack(spacing: 8) {
                Image(systemName: "paperplane")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Forward message + attachments to (blank = no forward)", text: Binding(
                    get: { rules?.rules[i].action.forwardTo ?? "" },
                    set: { rules?.rules[i].action.forwardTo = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private enum ActionKey { case markRead, leave, draftReply }

    private func bindingFor(_ key: ActionKey, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                switch key {
                case .markRead: return rules?.rules[index].action.markRead == true
                case .leave: return rules?.rules[index].action.leave == true
                case .draftReply: return rules?.rules[index].action.draftReply == true
                }
            },
            set: { newValue in
                guard var rules else { return }
                switch key {
                case .markRead: rules.rules[index].action.markRead = newValue
                case .leave: rules.rules[index].action.leave = newValue
                case .draftReply: rules.rules[index].action.draftReply = newValue
                }
                self.rules = rules
            }
        )
    }

    // MARK: - Forward types

    private func forwardSection(_ r: PostmarkRules) -> some View {
        SectionCard(title: "Forward to Silo", subtitle: "Only these document types are forwarded to your Silo inbound address.") {
            HStack(spacing: 10) {
                ForEach(r.attachment.forward.onlyTypes, id: \.self) { type in
                    Text(type)
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            Text("Production address is configured in Settings → Silo (Keychain). A debug build forwards to the dev address.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Save / load

    private var saveBar: some View {
        HStack {
            Spacer()
            Button("Save rules", action: save)
            switch saveState {
            case .idle: EmptyView()
            case .saved: Text("Saved").font(.system(size: 11)).foregroundStyle(.green)
            case .failed(let msg): Text(msg).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private func load() {
        loadError = nil
        rules = RulesStore.shared.load()
        if rules == nil { loadError = "Could not load PostmarkRules.json — it may be invalid. Reset it by deleting the file and relaunching." }
    }

    private func save() {
        guard var rules else { return }
        do {
            try RulesStore.shared.save(rules: rules)
            saveState = .saved
            NotificationCenter.default.post(name: SettingsStore.triageSettingDidChange, object: nil)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}