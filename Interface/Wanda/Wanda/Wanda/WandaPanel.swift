//
//  WandaPanel.swift
//  Wanda
//

import AppKit
import SwiftUI

/// A floating, glass-backed window that can be dragged anywhere and remembers its position.
final class WandaPanel: NSPanel {
    private static let autosaveName = "WandaPanel"

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
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

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        contentView = glass

        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { true }

    /// True until the user has moved the window once; used to place it under the menu bar icon.
    static var hasSavedPosition: Bool {
        UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: WandaPanel!
    private let server = ServerManager()
    private let microphone = Microphone()
    private lazy var assistant = Assistant(server: server, microphone: microphone)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app; don't put up a window or menu bar icon for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Start the server right away (if it isn't already running), even before the
        // window is opened.
        Task { await server.ensureRunning() }
        panel = WandaPanel(rootView: ContentView(assistant: assistant))

        // "Hey Wanda" brings the window forward and starts listening.
        assistant.onWake = { [weak self] in self?.showPanel() }
        assistant.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "AppIcon")
            button.setAccessibilityLabel("Wanda")
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stopIfLaunched()
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
