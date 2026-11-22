import AppKit
import os
import SwiftUI

/// One entry of the settings sidebar.
public struct CDSidebarItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let symbol: String
    /// The fill of the item's icon, as each pane of System Settings has a colour of its own.
    public let color: Color
    /// True when a separator and a gap come before this item, starting a new group.
    public let startsGroup: Bool

    public init(id: ID, title: String, symbol: String, color: Color = .gray, startsGroup: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
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
    /// Always `.all`: as in System Settings the sidebar cannot be collapsed. `SidebarLock` stops the divider from
    /// collapsing it; should a collapse still happen (a split view the lock cannot find), it is undone at once,
    /// because in accessory mode there is no View menu to bring the sidebar back.
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The widest the brand row has asked to be while the window is open. The sidebar never gets narrower, so the
    /// app's name and state always show in full; it only grows, so a state line that changes does not make it jump.
    @State private var brandWidth: CGFloat = 0

    /// The sidebar's usual width range; it widens past these when the brand row needs more.
    private static var minimumSidebar: CGFloat { 210 }
    private static var idealSidebar: CGFloat { 230 }
    private static var maximumSidebar: CGFloat { 260 }
    /// The list's own margins around a row's content, on both sides together.
    private static var rowMargins: CGFloat { 40 }

    public init(items: [CDSidebarItem<ID>], selection: Binding<ID>,
                @ViewBuilder brand: () -> Brand, @ViewBuilder detail: @escaping (ID) -> Detail) {
        self.items = items
        self._selection = selection
        self.brand = brand()
        self.detail = detail
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            let needed = brandWidth + Self.rowMargins
            sidebar
                .navigationSplitViewColumnWidth(min: max(Self.minimumSidebar, needed),
                                                ideal: max(Self.idealSidebar, needed),
                                                max: max(Self.maximumSidebar, needed))
        } detail: {
            detail(selection)
                .navigationTitle(items.first { $0.id == selection }?.title ?? "")
        }
        // The macOS 13 form of `onChange`, so the rule holds on every version the kit supports.
        .onChange(of: columns) { if $0 != .all { columns = .all } }
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
            // No tag: this row cannot be selected. A hidden copy at its natural width measures what it needs.
            brand
                .background(alignment: .leading) {
                    brand
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: BrandWidthKey.self, value: proxy.size.width)
                        })
                }
                .onPreferenceChange(BrandWidthKey.self) { width in
                    if width > brandWidth { brandWidth = width }
                }
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
                        Label {
                            Text(item.title)
                        } icon: {
                            CDSettingsIcon(symbol: item.symbol, color: item.color)
                        }
                        .tag(item.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarLock())
        if #available(macOS 14, *) {
            // As in System Settings, the sidebar cannot be collapsed.
            list.toolbar(removing: .sidebarToggle)
        } else {
            list
        }
    }
}

/// The brand row's natural width, for the sidebar's minimum.
private struct BrandWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Stops the sidebar from collapsing when its divider is dragged to the left. SwiftUI has no setting for this, so it
/// finds the AppKit split view that `NavigationSplitView` sits on and turns off collapsing for its first item, the
/// sidebar. Without this, the drag collapses the sidebar and the shell has to bring it back, which looks broken.
private struct SidebarLock: NSViewRepresentable {
    private static let log = Logger(subsystem: "app.clamdown", category: "settings")

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The split view controller finishes setting up its items after the view joins the window.
            DispatchQueue.main.async { [weak self] in self?.lock() }
        }

        private func lock() {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let sidebar = controller.splitViewItems.first {
                    sidebar.canCollapse = false
                    SidebarLock.log.info("sidebar locked against collapsing")
                    return
                }
                view = current.superview
            }
            SidebarLock.log.error("no split view above the sidebar; it can still be collapsed by dragging")
        }
    }
}
