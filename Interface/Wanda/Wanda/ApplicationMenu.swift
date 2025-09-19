//
//  ApplicationMenu.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/11/24.
//
//
//import Foundation
//import SwiftUI
//import Cocoa
//import AppKit
//
//class TransparentWindow: NSWindow {
//    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
//        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
//        
//        // Set the window's background color to clear
//        self.backgroundColor = NSColor(red: 0.8, green: 0.0, blue: 0.5, alpha: 0.3)
//        // Make the window non-opaque
//        self.isOpaque = true
//        
//        // Remove the window's shadow
//        self.hasShadow = false
//    }
//}
//
//struct TransparentWindowRepresentable: NSViewRepresentable {
//    func makeNSView(context: Context) -> NSView {
//        let view = NSView()
//        
//        // Access the window and set the transparency properties
//        DispatchQueue.main.async {
//            if let window = view.window {
//                window.backgroundColor = NSColor(red: 0.4, green: 0.0, blue: 0.5, alpha: 0.3)
//                window.isOpaque = true
//                window.hasShadow = true
//                window.titlebarAppearsTransparent = true
//                
//                // Customizing the title text color
//                window.titleVisibility = .hidden
//                let titleLabel = NSTextField(labelWithString: "Wanda")
//                titleLabel.textColor = NSColor.white
//                titleLabel.alignment = .center
//                titleLabel.isEditable = false
//                titleLabel.isBezeled = false
//                titleLabel.drawsBackground = false
//                titleLabel.sizeToFit()
//                
//                if let titlebarContainerView = window.standardWindowButton(.closeButton)?.superview {
//                    titlebarContainerView.addSubview(titleLabel)
//                    titleLabel.translatesAutoresizingMaskIntoConstraints = false
//                    NSLayoutConstraint.activate([
//                        titleLabel.centerXAnchor.constraint(equalTo: titlebarContainerView.centerXAnchor),
//                        titleLabel.centerYAnchor.constraint(equalTo: titlebarContainerView.centerYAnchor)
//                    ])
//                }
//            }
//        }
//        
//        return view
//    }
//    
//    func updateNSView(_ nsView: NSView, context: Context) {}
//}
//
//class ApplicationMenu: NSObject{
//    let menu = NSMenu()
//    @objc func openContentWindowAction() {
//            openContentWindow()
//        }
//    func openContentWindow() {
//        let contentView = ContentView().background(TransparentWindowRepresentable().ignoresSafeArea())
//        let hostingController = NSHostingController(rootView: contentView)
//        let window = NSWindow(contentViewController: hostingController)
//        window.setContentSize(NSSize(width: 400, height: 200))
//        window.styleMask = [.titled, .closable, .resizable]
//        window.title = "Content Window"
//        window.makeKeyAndOrderFront(nil)
//    }
//    func createMenu() -> NSMenu {
//        let wandaView = ContentView().background(TransparentWindowRepresentable().ignoresSafeArea())
//        let topView = NSHostingController(rootView: wandaView)
//        topView.view.frame.size = CGSize(width: 400, height: 200)
//        let customMenuItem = NSMenuItem()
//        customMenuItem.view = topView.view
////        menu.addItem(customMenuItem)
//        let openContentWindowItem = NSMenuItem(title: "Wanda", action: #selector(openContentWindowAction), keyEquivalent: "O")
//        openContentWindowItem.target = self
//        menu.addItem(openContentWindowItem)
//        menu.addItem(NSMenuItem.separator())
//        return menu
//    }
//}
