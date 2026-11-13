import SwiftUI

/// One entry of the settings sidebar.
public struct CDSidebarItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let symbol: String
    /// True when a separator and a gap come before this item, starting a new group.
    public let startsGroup: Bool

    public init(id: ID, title: String, symbol: String, startsGroup: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.startsGroup = startsGroup
    }
}

/// The settings window: a system sidebar (glass on macOS 26 and later) with a brand row on top, and the page of the
/// selected item beside it. The window title follows the page.
public struct CDSettingsShell<ID: Hashable, Brand: View, Detail: View>: View {
    private let items: [CDSidebarItem<ID>]
    @Binding private var selection: ID
    private let brand: Brand
    private let detail: (ID) -> Detail

    public init(items: [CDSidebarItem<ID>], selection: Binding<ID>,
                @ViewBuilder brand: () -> Brand, @ViewBuilder detail: @escaping (ID) -> Detail) {
        self.items = items
        self._selection = selection
        self.brand = brand()
        self.detail = detail
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            detail(selection)
                .navigationTitle(items.first { $0.id == selection }?.title ?? "")
        }
    }

    /// The items cut into groups at every item that starts one.
    private var groups: [[CDSidebarItem<ID>]] {
        var result: [[CDSidebarItem<ID>]] = []
        for item in items {
            if item.startsGroup || result.isEmpty {
                result.append([item])
            } else {
                result[result.count - 1].append(item)
            }
        }
        return result
    }

    @ViewBuilder
    private var sidebar: some View {
        let list = List(selection: Binding<ID?>(get: { selection }, set: { if let new = $0 { selection = new } })) {
            // No tag: this row cannot be selected.
            brand
                .listRowSeparator(.hidden)
            // Each group is a section of its own, so a separator row belongs to no item and is never highlighted
            // with the item after it.
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Section {
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(group) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        if #available(macOS 14, *) {
            // As in System Settings, the sidebar cannot be collapsed.
            list.toolbar(removing: .sidebarToggle)
        } else {
            list
        }
    }
}
