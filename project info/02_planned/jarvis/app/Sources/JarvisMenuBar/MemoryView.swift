import SwiftUI

/// Lets the user browse, add, edit, and delete memory entries. The view is
/// the only place that talks to `Memory` directly — it loads the full list
/// on appear, mutates it through `set` / `delete`, and re-reads after each
/// change so the UI is always backed by a fresh database read.
struct MemoryView: View {
    let memory: Memory

    @State private var entries: [MemoryEntry] = []
    @State private var loadError: String?
    @State private var mutationError: String?
    @State private var filter: MemoryCategoryFilter = .all
    @State private var editing: MemoryEntry?
    @State private var isCreating = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Memory").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("Jarvis reads these facts at the start of every Ask Jarvis run. Add identity items (your name, email), preferences (your editor), and facts (your work directory) so the model can act on them without re-asking.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(MemoryCategoryFilter.allOptions) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                Spacer()
                Button("+ New") { isCreating = true }
            }

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
            if let mutationError {
                Text(mutationError).font(.caption).foregroundStyle(.red)
            }

            if entries.isEmpty {
                Text("No memory entries yet. Use “+ New” to add one.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleGroups, id: \.0) { category, items in
                            categorySection(category: category, items: items)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
        }
        .padding(20)
        .task { await refresh() }
        .sheet(item: $editing) { entry in
            MemoryEntrySheet(
                title: "Edit entry",
                initialCategory: entry.category,
                initialKey: entry.key,
                initialValue: entry.value,
                onSubmit: { category, key, value in
                    await update(entry: entry, category: category, key: key, value: value)
                }
            )
        }
        .sheet(isPresented: $isCreating) {
            MemoryEntrySheet(
                title: "New entry",
                initialCategory: "preference",
                initialKey: "",
                initialValue: "",
                onSubmit: { category, key, value in
                    await create(category: category, key: key, value: value)
                }
            )
        }
    }

    @ViewBuilder
    private func categorySection(category: String, items: [MemoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.capitalized).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.key)
                            .font(.system(.body, design: .monospaced))
                        Spacer(minLength: 8)
                        Text(entry.value)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button {
                            editing = entry
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit \(entry.key)")
                        Button(role: .destructive) {
                            Task { await delete(entry) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(entry.key)")
                    }
                    .padding(.vertical, 6)
                    if offset < items.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    /// Filter selection. `.all` shows every entry; `.category(name)` restricts
    /// the list to that category. The picker shows the conventional
    /// categories in a stable order.
    enum MemoryCategoryFilter: Hashable, Identifiable {
        case all
        case category(String)

        var id: String {
            switch self {
            case .all: return "all"
            case .category(let name): return name
            }
        }

        var label: String {
            switch self {
            case .all: return "All"
            case .category(let name): return name
            }
        }

        static let allOptions: [MemoryCategoryFilter] = [
            .all,
            .category("identity"),
            .category("preference"),
            .category("fact"),
        ]

        func matches(_ category: String) -> Bool {
            switch self {
            case .all: return true
            case .category(let name): return name == category
            }
        }
    }

    /// Groups the visible entries by category, in the conventional display
    /// order (identity, preference, fact) regardless of insertion order.
    private var visibleGroups: [(String, [MemoryEntry])] {
        let filtered = entries.filter { filter.matches($0.category) }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        return ["identity", "preference", "fact"].compactMap { name in
            guard let items = grouped[name], !items.isEmpty else { return nil }
            return (name, items)
        }
    }

    private func refresh() async {
        do {
            entries = try await memory.list(category: nil)
            loadError = nil
        } catch {
            loadError = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    private func create(category: String, key: String, value: String) async {
        do {
            try await memory.set(category: category, key: key, value: value)
            mutationError = nil
            await refresh()
        } catch {
            mutationError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func update(entry: MemoryEntry, category: String, key: String, value: String) async {
        do {
            // `set` is an upsert keyed by (category, key). When the edit keeps
            // the same composite key, the row updates in place; when either
            // piece changes, the old row is deleted first so the new (category,
            // key) pair is created rather than leaving a stale entry behind.
            if entry.category != category || entry.key != key {
                try await memory.delete(id: entry.id)
            }
            try await memory.set(category: category, key: key, value: value)
            mutationError = nil
            await refresh()
        } catch {
            mutationError = "Failed to update: \(error.localizedDescription)"
        }
    }

    private func delete(_ entry: MemoryEntry) async {
        do {
            try await memory.delete(id: entry.id)
            mutationError = nil
            await refresh()
        } catch {
            mutationError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

/// Modal sheet for creating or editing one memory entry. Validates that
/// key and value are non-empty before allowing a save; category is selected
/// from the conventional three.
private struct MemoryEntrySheet: View {
    let title: String
    let initialCategory: String
    let initialKey: String
    let initialValue: String
    let onSubmit: (String, String, String) async -> Void

    private static let categories: [String] = ["identity", "preference", "fact"]

    @State private var category: String
    @State private var key: String
    @State private var value: String
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        initialCategory: String,
        initialKey: String,
        initialValue: String,
        onSubmit: @escaping (String, String, String) async -> Void
    ) {
        self.title = title
        self.initialCategory = initialCategory
        self.initialKey = initialKey
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        let resolvedCategory = Self.categories.contains(initialCategory) ? initialCategory : "preference"
        _category = State(initialValue: resolvedCategory)
        _key = State(initialValue: initialKey)
        _value = State(initialValue: initialValue)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Category").font(.caption).foregroundStyle(.secondary)
                Picker("Category", selection: $category) {
                    ForEach(Self.categories, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                TextField("editor", text: $key)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                TextField("vim", text: $value)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func submit() async {
        isSubmitting = true
        await onSubmit(category, key, value)
        isSubmitting = false
        dismiss()
    }
}