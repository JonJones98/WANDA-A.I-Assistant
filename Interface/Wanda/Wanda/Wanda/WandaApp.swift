//
//  WandaApp.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/6/24.
//

import SwiftUI
import Cocoa
import AppKit

class TransparentWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        
        // Set the window's background color to clear
        self.backgroundColor = NSColor(red: 0.8, green: 0.0, blue: 0.5, alpha: 0.3)
        // Make the window non-opaque
        self.isOpaque = true
        
        // Remove the window's shadow
        self.hasShadow = false
    }
}

struct TransparentWindowRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        
        // Access the window and set the transparency properties
        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = NSColor(red: 0.4, green: 0.0, blue: 0.5, alpha: 0.3)
                window.isOpaque = true
                window.hasShadow = true
                window.titlebarAppearsTransparent = true
                
                // Customizing the title text color
                window.titleVisibility = .hidden
                let titleLabel = NSTextField(labelWithString: "Wanda")
                titleLabel.textColor = NSColor.white
                titleLabel.alignment = .center
                titleLabel.isEditable = false
                titleLabel.isBezeled = false
                titleLabel.drawsBackground = false
                titleLabel.sizeToFit()
                
                if let titlebarContainerView = window.standardWindowButton(.closeButton)?.superview {
                    titlebarContainerView.addSubview(titleLabel)
                    titleLabel.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        titleLabel.centerXAnchor.constraint(equalTo: titlebarContainerView.centerXAnchor),
                        titleLabel.centerYAnchor.constraint(equalTo: titlebarContainerView.centerYAnchor)
                    ])
                }
            }
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings{
                     EmptyView()
                 }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate!
    lazy var statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var contentWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        NSApp.applicationIconImage = NSImage(named: NSImage.Name("AppIcon"))
        statusBarItem.button?.image = NSImage(named: NSImage.Name("AppIcon"))
        statusBarItem.button?.imagePosition = .imageLeading
        statusBarItem.button?.action = #selector(statusBarButtonClicked)
    }

    @objc func statusBarButtonClicked() {
        if contentWindow == nil {
            openContentWindow()
        } else {
            contentWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func openContentWindow() {
        let contentView = ContentView().background(TransparentWindowRepresentable().ignoresSafeArea()).frame(maxWidth:400)
        let hostingController = NSHostingController(rootView: contentView)
        contentWindow = NSWindow(contentViewController: hostingController)
        contentWindow?.setContentSize(NSSize(width: 400, height: 200))
        contentWindow?.styleMask = [.titled, .closable, .resizable]
        contentWindow?.makeKeyAndOrderFront(nil)
        contentWindow?.setFrameTopLeftPoint(NSPoint(x: 10, y: NSScreen.main!.visibleFrame.maxY-10))
        // Change the status bar icon when the window opens
        statusBarItem.button?.image = NSImage(named: NSImage.Name("AppIcon"))
    }
}
