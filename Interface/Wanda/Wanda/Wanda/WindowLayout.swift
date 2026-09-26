//
//  WindowLayout.swift
//  Wanda
//

import Foundation

/// How Wanda's window is laid out: full chat or a minimal Siri-style card, whether the
/// chat history sidebar is open, and the chat area's size. Saved between launches;
/// `AppDelegate` resizes the window when it changes.
@MainActor
final class WindowLayout: ObservableObject {
    enum Mode: String {
        case normal
        case minimal
    }

    static let sidebarWidth: CGFloat = 220
    static let minimalWidth: CGFloat = 380
    static let standardSize = CGSize(width: 400, height: 560)
    static let largeSize = CGSize(width: 680, height: 760)
    static let minimumChatSize = CGSize(width: 360, height: 420)

    private enum Key {
        static let mode = "WandaWindowMode"
        static let sidebar = "WandaShowsSidebar"
        static let width = "WandaChatWidth"
        static let height = "WandaChatHeight"
    }

    @Published var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    @Published var showsSidebar: Bool {
        didSet { defaults.set(showsSidebar, forKey: Key.sidebar) }
    }
    /// The chat area's size in normal mode, not counting the sidebar.
    @Published var chatSize: CGSize {
        didSet {
            defaults.set(Double(chatSize.width), forKey: Key.width)
            defaults.set(Double(chatSize.height), forKey: Key.height)
        }
    }
    /// The minimal card's height, which follows its content.
    @Published var minimalHeight: CGFloat = 120

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .normal
        showsSidebar = defaults.bool(forKey: Key.sidebar)
        let width = defaults.double(forKey: Key.width)
        let height = defaults.double(forKey: Key.height)
        chatSize = width > 0 && height > 0 ? CGSize(width: width, height: height) : Self.standardSize
    }

    var isExpanded: Bool {
        chatSize.width >= Self.largeSize.width && chatSize.height >= Self.largeSize.height
    }

    func toggleExpanded() {
        chatSize = isExpanded ? Self.standardSize : Self.largeSize
    }

    /// The window content size for the current layout.
    var contentSize: CGSize {
        switch mode {
        case .minimal:
            return CGSize(width: Self.minimalWidth, height: minimalHeight)
        case .normal:
            return CGSize(width: chatSize.width + (showsSidebar ? Self.sidebarWidth : 0), height: chatSize.height)
        }
    }
}
