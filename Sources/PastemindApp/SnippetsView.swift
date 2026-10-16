import AppKit
import SwiftUI
import PastemindKit

/// The snippets mode's body: the folders and snippets matching the query on the left (in a folder, its snippets), the
/// selected one's editor on the right.
struct SnippetsContent: View {
    let controller: PanelController

    /// The "New snippet" button's row, under the list.
    private static let buttonRow: CGFloat = 34

    var body: some View {
        if controller.snippetRows.isEmpty {
            SnippetsEmpty(controller: controller)
        } else {
            HStack(spacing: 0) {
                // "New snippet" right under the last snippet; with more than fit, under the list, which scrolls.
                GeometryReader { geometry in
                    let count = CGFloat(controller.snippetRows.count)
                    let rows = SnippetList.top + count * SnippetCell.height + max(count - 1, 0) * SnippetList.gap
                        + SnippetList.bottom
                    VStack(alignment: .leading, spacing: 0) {
                        SnippetList(controller: controller)
                            .frame(height: min(rows, geometry.size.height - Self.buttonRow))
                        NewButtons(controller: controller)
                            .padding(.leading, SnippetList.inset + 8)
                            .frame(height: Self.buttonRow, alignment: .top)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: PanelController.listWidth)
                Divider()
                Group {
                    if let snippet = controller.selectedSnippet {
                        SnippetEditor(snippet: snippet, controller: controller)
                            .id(snippet.id)
                    } else if let folder = controller.selectedFolder {
                        FolderEditor(folder: folder, controller: controller)
                            .id(folder.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct SnippetsEmpty: View {
    let controller: PanelController
    private var query: String { controller.query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: controller.openFolder == nil ? "text.quote" : "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            NewButtons(controller: controller)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if let folder = controller.openFolder {
            let empty = !controller.app.snippets.contains { $0.folder == folder.id }
            return empty ? "“\(folder.name)” is empty" : "No snippet in “\(folder.name)” matches"
        }
        return controller.app.snippets.isEmpty ? "No snippets yet" : "No snippet matches"
    }

    private var detail: String {
        if controller.openFolder != nil {
            return (query.isEmpty ? "⌘N makes one here." : "⌘N makes one here named “\(query)”.")
                + " Esc goes back to all snippets."
        }
        if controller.app.snippets.isEmpty {
            return "Text you paste again and again: an email, an address, a reply.\n"
                + "⌘N makes one; ⌘S in the history keeps the selected clip as one."
        }
        return "⌘N makes one named “\(query)”."
    }
}

/// "+ New snippet" (as ⌘N makes), and at the top "+ New folder" (⇧⌘N).
private struct NewButtons: View {
    let controller: PanelController

    var body: some View {
        HStack(spacing: 6) {
            NewButton(title: "New snippet", help: "A new snippet (⌘N)") { controller.newSnippet() }
            if controller.snippetFolder == nil {
                NewButton(title: "New folder", help: "A new folder of snippets (⇧⌘N)") { controller.newFolder() }
            }
        }
    }
}

private struct NewButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .capsuleChrome(interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }
}

/// Deleting can't be undone: the first click asks ("Delete?", in red), the second deletes; the pointer going asks
/// no more.
private struct DeleteButton: View {
    let help: String
    let delete: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { delete() } else { armed = true }
        } label: {
            if armed {
                ConfirmLabel(title: "Delete?")
            } else {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: ConfirmLabel.height, height: ConfirmLabel.height)
                    .capsuleChrome(interactive: true)
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .background(HoverArea { inside in if !inside { armed = false } })
        .help(help)
    }
}

/// The snippets matching the query: an AppKit list, as the history's (see `ListView`).
private struct SnippetList: View {
    static let inset: CGFloat = 8
    static let top: CGFloat = 8
    static let bottom: CGFloat = 8
    static let gap: CGFloat = 1
    let controller: PanelController

    var body: some View {
        SnippetTable(controller: controller, shown: .init(
            rows: controller.snippetRows, selection: controller.snippetSelection,
            resultsVersion: controller.resultsVersion, folders: controller.app.snippetFolders,
            inFolder: controller.snippetFolder != nil))
    }
}

private struct SnippetTable: NSViewRepresentable {
    struct Shown {
        var rows: [SnippetRow]
        var selection: SnippetRow.ID?
        var resultsVersion: Int
        /// For the names of the folders snippets found at the top are in.
        var folders: [SnippetFolder]
        var inFolder: Bool
    }

    let controller: PanelController
    let shown: Shown

    func makeNSView(context: Context) -> ListView {
        let list = ListView(layout: .init(inset: SnippetList.inset, top: SnippetList.top, bottom: SnippetList.bottom,
                                          gap: SnippetList.gap))
        list.source = context.coordinator
        list.reorderable = true
        return list
    }

    func updateNSView(_ list: ListView, context: Context) {
        context.coordinator.update(shown, list)
    }

    func makeCoordinator() -> Rows { Rows(controller: controller) }

    final class Rows: ListSource {
        private let controller: PanelController
        private var rows: [SnippetRow]?
        private var folderNames: [Int64: String] = [:]
        private var inFolder = false
        private var selection: SnippetRow.ID?
        private var resultsVersion = 0

        init(controller: PanelController) { self.controller = controller }

        func update(_ shown: Shown, _ list: ListView) {
            let selected = shown.selection.flatMap { id in shown.rows.firstIndex { $0.id == id } }
            let names = Dictionary(shown.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            if shown.rows != rows || names != folderNames || shown.inFolder != inFolder {
                rows = shown.rows
                folderNames = names
                inFolder = shown.inFolder
                list.reload(selected: selected)
            } else {
                list.select(selected)
            }
            if shown.resultsVersion != resultsVersion {
                list.scrollToTop()
            } else if shown.selection != selection, let selected {
                list.scrollToVisible(selected)
            }
            selection = shown.selection
            resultsVersion = shown.resultsVersion
        }

        var rowCount: Int { rows?.count ?? 0 }

        func rowHeight(_ row: Int) -> CGFloat { SnippetCell.height }

        func cell(_ row: Int, in list: ListView) -> ListCell {
            switch rows![row] {
            case .folder(let folder, let count):
                let cell = list.reuse(FolderCell.self)
                cell.configure(folder, count: count)
                return cell
            case .snippet(let snippet):
                // ⌘1…⌘9 count the snippets only; one found in a folder says which.
                let number = rows![..<row].filter { $0.snippet != nil }.count + 1
                let cell = list.reuse(SnippetCell.self)
                cell.configure(snippet, folder: inFolder ? nil : snippet.folder.flatMap { folderNames[$0] },
                               shortcut: number <= 9 ? number : nil)
                return cell
            }
        }

        /// A snippet drags out as its text (in Finder a .txt named after it); a folder doesn't.
        func dragWriters(_ row: Int) -> [NSPasteboardWriting] {
            guard let snippet = rows?[row].snippet else { return [] }
            return ClipDrag.writers(for: snippet)
        }

        func dragBegan(_ row: Int) { controller.dragBegan() }
        func dragEnded(_ row: Int, dropped: Bool) { controller.dragEnded(dropped: dropped) }
        func reorderRange(_ row: Int) -> Range<Int>? { controller.reorderRange(for: row) }
        func reorder(_ row: Int, to index: Int) { controller.moveSnippetRow(row, to: index) }

        func click(_ row: Int, count: Int) {
            guard let picked = rows?[row] else { return }
            controller.selectSnippet(picked.id)
            guard count >= 2 else { return }
            if let folder = picked.folder { controller.openFolder(folder) } else { controller.paste(plain: false) }
        }
    }
}

/// The selected snippet, to edit in place: its name, its text, saved as you type. Esc goes back to the search.
private struct SnippetEditor: View {
    let snippet: Snippet
    let controller: PanelController
    @State private var title: String
    @State private var text: String
    @FocusState private var focus: Field?

    private enum Field { case title, text }

    init(snippet: Snippet, controller: PanelController) {
        self.snippet = snippet
        self.controller = controller
        _title = State(initialValue: snippet.title)
        _text = State(initialValue: snippet.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .text }
                if !controller.app.snippetFolders.isEmpty { folderMenu }
                deleteButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
            TextEditor(text: $text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .text)
                .padding(.horizontal, 13)   // with the text view's own 5 points, 18 like the name
                .padding(.bottom, 8)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("The text to paste")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 18)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            Text(details)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onChange(of: title) { _, _ in save() }
        .onChange(of: text) { _, _ in save() }
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: controller.focusTitleOf) { _, _ in takeFocusIfAsked() }
    }

    private func save() {
        var changed = snippet
        changed.title = title
        changed.text = text
        controller.updateSnippet(changed)
    }

    private func takeFocusIfAsked() {
        guard controller.focusTitleOf == snippet.id else { return }
        controller.focusTitleOf = nil
        DispatchQueue.main.async { focus = .title }
    }

    /// The folder it's in, to move it to another (or out of any).
    private var folderMenu: some View {
        let current = controller.app.snippets.first { $0.id == snippet.id }?.folder
        let folders = controller.app.snippetFolders
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let name = current.flatMap { id in folders.first { $0.id == id }?.name }
        return Menu {
            Picker("Folder", selection: Binding(get: { current }, set: { controller.moveSnippet(snippet, to: $0) })) {
                Text("No folder").tag(Int64?.none)
                ForEach(folders) { folder in Text(folder.name).tag(Int64?.some(folder.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(name ?? "No folder")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .capsuleChrome(interactive: true)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The folder it's in")
    }

    private var deleteButton: some View {
        DeleteButton(help: "Delete this snippet") { controller.deleteSnippet(snippet) }
    }

    private var details: String {
        let current = controller.app.snippets.first { $0.id == snippet.id } ?? snippet
        if let used = current.lastUsed {
            let times = current.uses == 1 ? "once" : "\(current.uses) times"
            return "Pasted \(times) · last \(When.long(used).lowercasedFirst)"
        }
        return "Not pasted yet · made \(When.long(current.created).lowercasedFirst)"
    }
}

/// The selected folder: its name to edit in place, how many snippets it has, ↩ to open it.
private struct FolderEditor: View {
    let folder: SnippetFolder
    let controller: PanelController
    @State private var name: String
    @FocusState private var editing: Bool

    init(folder: SnippetFolder, controller: PanelController) {
        self.folder = folder
        self.controller = controller
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .focused($editing)
                    .onSubmit { controller.focusSearch() }   // and ↩ opens it
                deleteButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
            Text(contents)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 4) {
                Keycap(key: "↩")
                Text("opens it · made \(When.long(folder.created).lowercasedFirst)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: name) { _, _ in
            var renamed = folder
            renamed.name = name
            controller.renameFolder(renamed)
        }
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: controller.focusFolderNameOf) { _, _ in takeFocusIfAsked() }
    }

    private var contents: String {
        let count = controller.app.snippets.filter { $0.folder == folder.id }.count
        return count == 0 ? "No snippets in it yet" : count == 1 ? "1 snippet" : "\(count) snippets"
    }

    private func takeFocusIfAsked() {
        guard controller.focusFolderNameOf == folder.id else { return }
        controller.focusFolderNameOf = nil
        DispatchQueue.main.async { editing = true }
    }

    /// Its snippets stay, at the top.
    private var deleteButton: some View {
        DeleteButton(help: "Delete this folder (its snippets stay)") { controller.deleteFolder(folder) }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
