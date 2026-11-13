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

    @ViewBuilder
    private var sidebar: some View {
        let list = List(selection: Binding<ID?>(get: { selection }, set: { if let new = $0 { selection = new } })) {
            // No tag: this row cannot be selected.
            brand
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)
            ForEach(items) { item in
                if item.startsGroup {
                    Divider()
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                }
                Label(item.title, systemImage: item.symbol)
                    .tag(item.id)
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
