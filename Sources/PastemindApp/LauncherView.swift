import AppKit
import SwiftUI
import PastemindKit

/// The search panel's field row.
struct LauncherHeaderView: View {
    @Bindable var controller: LauncherController

    var body: some View {
        PanelHeader(symbol: controller.symbol, text: $controller.query, placeholder: controller.placeholder,
                    onField: { controller.field = $0 }, onSymbol: { controller.symbolView = $0 },
                    onPlaceholder: { controller.placeholderView = $0 }) {
            OptionsButton(app: controller.app, opened: controller.opened, quietly: controller.openedQuietly,
                          query: controller.query, busy: controller.spinning)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanelChrome.fieldHeight)
        .background(PanelChrome.tint)
    }
}

/// The search panel's body: the results.
struct LauncherBodyView: View {
    let controller: LauncherController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.results.isEmpty {
                InsetDivider()
                ResultsList(controller: controller)
            } else if controller.searchingFiles && controller.filesOnly {
                InsetDivider()
                Text("Searching files…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: LauncherController.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(width: LauncherController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelChrome.tint)
    }
}

/// From the rows to the window's edges: the same at the sides and the bottom, so the selection's corners follow the
/// window's.
enum LaunchList {
    static let inset: CGFloat = 7
}

/// The results: an AppKit list, as the clipboard history's (see `ListView`).
private struct ResultsList: View {
    let controller: LauncherController

    var body: some View {
        ResultsTable(controller: controller, shown: .init(
            results: controller.results, selection: controller.selection, resultsVersion: controller.resultsVersion))
    }
}

private struct ResultsTable: NSViewRepresentable {
    struct Shown {
        var results: [LaunchResult]
        var selection: String?
        var resultsVersion: Int
    }

    let controller: LauncherController
    let shown: Shown

    func makeNSView(context: Context) -> ListView {
        let list = ListView(layout: .init(inset: LaunchList.inset, top: 6, bottom: LaunchList.inset, gap: 0))
        list.source = context.coordinator
        controller.list = list
        return list
    }

    func updateNSView(_ list: ListView, context: Context) {
        context.coordinator.update(shown, list)
    }

    func makeCoordinator() -> Rows { Rows(controller: controller) }

    final class Rows: ListSource {
        private let controller: LauncherController
        private var results: [LaunchResult]?
        private var selection: String?
        private var resultsVersion = 0

        init(controller: LauncherController) { self.controller = controller }

        func update(_ shown: Shown, _ list: ListView) {
            let selected = shown.selection.flatMap { id in shown.results.firstIndex { $0.id == id } }
            // A scroller only when there's more than fits.
            list.hasVerticalScroller = shown.results.count > LauncherController.visibleRows
            if shown.results != results {
                results = shown.results
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

        var rowCount: Int { results?.count ?? 0 }

        func rowHeight(_ row: Int) -> CGFloat { LauncherController.rowHeight }

        func cell(_ row: Int, in list: ListView) -> ListCell {
            let cell = list.reuse(LaunchCell.self)
            cell.configure(results![row], shortcut: row < 9 ? row + 1 : nil)
            return cell
        }

        func click(_ row: Int, count: Int) {
            guard let result = results?[row] else { return }
            controller.select(result.id)
            if count >= 2 { controller.open() }
        }
    }
}
