//
//  WandaPanel.swift
//  Wanda
//

import AppKit
import Combine
import SwiftUI

/// A floating, glass-backed window that can be dragged anywhere and remembers its position.
final class WandaPanel: NSPanel {
    private static let autosaveName = "WandaPanel"
    /// Glass opacity in minimal mode; lower is more see-through.
    private static let minimalGlassOpacity: CGFloat = 0.5

    private let glass = NSVisualEffectView()

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: WindowLayout.standardSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }

        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Clear window + behind-window blur = frosted glass.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // The glass sits behind the content (not around it) so it can be made more
        // see-through in minimal mode without fading the text.
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let hosting = NSHostingView(rootView: rootView)
        // The window's size comes from `WindowLayout`, not from the SwiftUI content.
        hosting.sizingOptions = []
        let container = NSView()
        for view in [glass, hosting] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        contentView = container

        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { true }

    /// True until the user has moved the window once; used to place it under the menu bar icon.
    static var hasSavedPosition: Bool {
        UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
    }

    /// Resizes to `layout`, keeping the top-left corner where it is and staying on screen.
    @MainActor
    func apply(_ layout: WindowLayout, animate: Bool) {
        switch layout.mode {
        case .minimal:
            styleMask.remove(.resizable)
            contentMinSize = NSSize(width: WindowLayout.minimalWidth, height: 40)
        case .normal:
            styleMask.insert(.resizable)
            let sidebar = layout.showsSidebar ? WindowLayout.sidebarWidth : 0
            contentMinSize = NSSize(
                width: WindowLayout.minimumChatSize.width + sidebar,
                height: WindowLayout.minimumChatSize.height
            )
        }

        var target = frameRect(forContentRect: NSRect(origin: .zero, size: layout.contentSize))
        target.origin = NSPoint(x: frame.minX, y: frame.maxY - target.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            target.size.height = min(target.height, visible.height)
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        let opacity = layout.mode == .minimal ? Self.minimalGlassOpacity : 1
        if glass.alphaValue != opacity {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate && isVisible ? 0.25 : 0
                glass.animator().alphaValue = opacity
            }
        }
        guard target != frame else { return }
        setFrame(target, display: true, animate: animate && isVisible)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: WandaPanel!
    private let server = ServerManager()
    private let microphone = Microphone()
    private let layout = WindowLayout()
    private lazy var assistant = Assistant(server: server, microphone: microphone)
    private var subscriptions: Set<AnyCancellable> = []
    private var occlusionObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app; don't put up a window or menu bar icon for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Start the server right away (if it isn't already running), even before the
        // window is opened.
        Task { await server.ensureRunning() }
        panel = WandaPanel(rootView: ContentView(assistant: assistant, layout: layout))
        panel.delegate = self
        panel.apply(layout, animate: false)
        observeLayout()

        // Tell the wake word listener whether the window is on screen, so that just saying
        // "Wanda" works while it's open.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.assistant.setWindowVisible(self.panel.occlusionState.contains(.visible))
            }
        }

        // "Hey Wanda" brings the window forward and starts listening.
        assistant.onWake = { [weak self] in self?.showPanel() }
        assistant.chat.showMinimalView = { [layout] minimal in layout.mode = minimal ? .minimal : .normal }
        assistant.chat.isMinimalView = { [layout] in layout.mode == .minimal }
        assistant.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "AppIcon")
            button.setAccessibilityLabel("Wanda")
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    /// Quitting Wanda (power button, ⌘Q, or the Mac shutting down) stops the server too.
    func applicationWillTerminate(_ notification: Notification) {
        assistant.musicDucker.restoreNow()
        server.stopServer()
    }

    /// Remember the size the user dragged the window to.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard layout.mode == .normal else { return }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        let sidebar = layout.showsSidebar ? WindowLayout.sidebarWidth : 0
        layout.chatSize = CGSize(width: content.width - sidebar, height: content.height)
    }

    private func observeLayout() {
        // Mode, sidebar and size changes animate; the minimal card's height follows its
        // content instantly. Values are read after the change lands (receive(on:)).
        Publishers.Merge3(
            layout.$mode.map { _ in true },
            layout.$showsSidebar.map { _ in true },
            layout.$chatSize.map { _ in true }
        )
        .merge(with: layout.$minimalHeight.map { _ in false })
        .dropFirst(4)
        .receive(on: RunLoop.main)
        .sink { [weak self] animate in
            guard let self else { return }
            self.panel.apply(self.layout, animate: animate)
        }
        .store(in: &subscriptions)
    }

    @objc private func togglePanel() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        if !WandaPanel.hasSavedPosition, let iconFrame = statusItem.button?.window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: iconFrame.midX - panel.frame.width / 2, y: iconFrame.minY - 6))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
