import SwiftUI

/// Live view over the activity journal: filter chips, search, follow-latest
/// auto-scroll, Clear (memory buffer only) and Open Log File.
struct ActivityWindowView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case mail = "Mail"
        case classify = "Classify"
        case actions = "Actions"
        case silo = "Silo"
        case errors = "Errors"

        var id: String { rawValue }
    }

    @ObservedObject private var log: ActivityLog
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var followLatest = true

    @MainActor
    init(log: ActivityLog) {
        _log = ObservedObject(initialValue: log)
    }

    private var filteredEntries: [ActivityLog.Entry] {
        log.entries.filter { entry in
            if !search.isEmpty {
                let haystack = "\(entry.message) \(entry.messageID ?? "")".lowercased()
                guard haystack.contains(search.lowercased()) else { return false }
            }
            switch filter {
            case .all:
                return true
            case .mail:
                return entry.kind == .poll
            case .classify:
                return entry.kind == .classify
            case .actions:
                return entry.kind == .action
            case .silo:
                return entry.kind == .silo
            case .errors:
                return entry.kind == .error || entry.level == .error
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            entriesList
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)

            Toggle("Follow latest", isOn: $followLatest)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

            Spacer()

            Button("Clear") {
                log.clear()
            }
            .help("Clears the in-memory log — the file is untouched")

            Button("Open Log File") {
                NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
            }
        }
        .padding(8)
    }

    // MARK: - List

    private var entriesList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                row(entry)
                    .id(entry.id)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .onChange(of: log.entries.count) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onAppear {
                scrollToLatest(using: proxy)
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard followLatest, let last = filteredEntries.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func row(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)

            Text(entry.kind.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(kindColor(entry.kind)))

            Text(entry.message)
                .font(.system(.body))
                .foregroundStyle(levelColor(entry.level))
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            if let messageID = entry.messageID {
                Text(messageID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .help(messageID)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Colors

    private func kindColor(_ kind: ActivityLog.Kind) -> Color {
        switch kind {
        case .app: return .gray
        case .poll: return Color(nsColor: .systemBlue).opacity(0.85)
        case .classify: return Color(nsColor: .systemPurple).opacity(0.85)
        case .action: return Color(nsColor: .systemOrange).opacity(0.85)
        case .silo: return Color(nsColor: .systemIndigo).opacity(0.85)
        case .error: return Color(nsColor: .systemRed).opacity(0.85)
        }
    }

    private func levelColor(_ level: ActivityLog.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}