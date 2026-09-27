//
//  WindowArranger.swift
//  Wanda
//

import AppKit
import ApplicationServices

/// Opens apps by name and arranges app windows to fit the screen side by side. Moving
/// other apps' windows uses the Accessibility API, which the user must allow once in
/// System Settings → Privacy & Security → Accessibility.
@MainActor
enum WindowArranger {
    // MARK: Finding and opening apps

    /// Everyday names for apps whose real names differ.
    nonisolated private static let aliases = [
        "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code",
        "code": "visual studio code", "settings": "system settings", "system preferences": "system settings",
        "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook", "teams": "microsoft teams", "itunes": "music", "apple music": "music",
    ]

    nonisolated private static let appFolders: [URL] = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", "/System/Library/CoreServices",
    ].map { URL(fileURLWithPath: $0) } + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]

    /// The app called `name` ("safari", "the notes app", "chrome"), or nil if there isn't one.
    nonisolated static func findApp(_ name: String) -> URL? {
        var key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        key = key.replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" (app|application)$"#, with: "", options: .regularExpression)
        key = aliases[key] ?? key
        guard !key.isEmpty else { return nil }

        let apps = appFolders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        .filter { $0.pathExtension == "app" }
        let named = { (app: URL) in app.deletingPathExtension().lastPathComponent.lowercased() }
        if let exact = apps.first(where: { named($0) == key }) { return exact }
        // "microsoft word" or "word" -> "Microsoft Word" if only one app fits.
        let partial = apps.filter { named($0).hasPrefix(key) || named($0).hasSuffix(" " + key) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Opens the apps and returns them once each has a window (or after `timeout`).
    static func open(_ urls: [URL], timeout: TimeInterval = 8) async -> [NSRunningApplication] {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        for url in urls {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
        let giveUp = Date().addingTimeInterval(timeout)
        var apps: [NSRunningApplication] = []
        while Date() < giveUp {
            apps = urls.compactMap(running)
            let ready = apps.count == urls.count
                && (!isAllowed || apps.allSatisfy { mainWindow(of: $0.processIdentifier) != nil })
            if ready { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Let the last windows finish appearing and settling.
        try? await Task.sleep(for: .milliseconds(500))
        return apps
    }

    /// The running copy of the app at `url`. Matched by bundle ID, not path: Safari, for
    /// one, runs from a hidden system volume rather than /Applications.
    static func running(_ url: URL) -> NSRunningApplication? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// The running app called `name`, if it's open.
    static func running(named name: String) -> NSRunningApplication? {
        findApp(name).flatMap(running)
    }

    /// Minimizes the app's main window to the Dock (or hides the app without
    /// Accessibility access).
    static func minimize(_ app: NSRunningApplication) {
        guard isAllowed, let window = mainWindow(of: app.processIdentifier) else {
            app.hide()
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: Arranging

    /// True if Wanda may move other apps' windows.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt to allow Wanda in Accessibility settings.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Apps with windows on screen, frontmost first, not counting Wanda.
    static func visibleApps(limit: Int = 6) -> [NSRunningApplication] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var seen = Set<pid_t>()
        var apps: [NSRunningApplication] = []
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  seen.insert(pid).inserted,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            apps.append(app)
            if apps.count == limit { break }
        }
        return apps
    }

    /// Puts each app's main window in its own part of the screen Wanda is on. Returns how
    /// many windows were moved.
    @discardableResult
    static func arrange(_ apps: [NSRunningApplication]) -> Int {
        guard isAllowed else { return 0 }
        let windows: [AXUIElement] = apps.compactMap { app in
            if app.isHidden { app.unhide() }
            return mainWindow(of: app.processIdentifier)
        }
        guard !windows.isEmpty, let screen = NSApp.keyWindow?.screen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return 0 }
        let frames = layout(count: windows.count, in: screen.visibleFrame)
        for (window, frame) in zip(windows, frames) {
            // Accessibility measures from the top-left of the main screen; AppKit from the bottom-left.
            var origin = CGPoint(x: frame.minX, y: primary.frame.maxY - frame.maxY)
            var size = frame.size
            guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { continue }
            // Move, resize, then move again: some apps won't grow past the screen edge.
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        for app in apps { app.activate() }
        NSApp.activate(ignoringOtherApps: true)
        return windows.count
    }

    /// Where `count` windows go in `area` (AppKit coordinates), first window first:
    /// 1 fills it, 2 side by side, 3 one big on the left and two stacked on the right,
    /// more in a grid whose last row stretches to fill.
    nonisolated static func layout(count: Int, in area: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0 else { return [] }
        let area = area.insetBy(dx: gap, dy: gap)
        func cell(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            // x and y as fractions from the top-left; shrink by half a gap on inner edges.
            CGRect(
                x: area.minX + x * area.width + (x > 0 ? gap / 2 : 0),
                y: area.maxY - (y + height) * area.height + (y + height < 1 ? gap / 2 : 0),
                width: width * area.width - (x > 0 ? gap / 2 : 0) - (x + width < 1 ? gap / 2 : 0),
                height: height * area.height - (y > 0 ? gap / 2 : 0) - (y + height < 1 ? gap / 2 : 0)
            )
        }
        switch count {
        case 1:
            return [area]
        case 2:
            return [cell(0, 0, 0.5, 1), cell(0.5, 0, 0.5, 1)]
        case 3:
            return [cell(0, 0, 0.5, 1), cell(0.5, 0, 0.5, 0.5), cell(0.5, 0.5, 0.5, 0.5)]
        default:
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            return (0..<count).map { index in
                let row = index / columns
                let inRow = row == rows - 1 ? count - row * columns : columns
                let width = 1 / CGFloat(inRow)
                let height = 1 / CGFloat(rows)
                return cell(CGFloat(index % columns) * width, CGFloat(row) * height, width, height)
            }
        }
    }

    /// The app's focused or main window, else its first normal window that isn't minimized.
    private static func mainWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                if isUsable(window) { return window }
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first(where: isUsable)
    }

    private static func isUsable(_ window: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        return (subrole as? String) == kAXStandardWindowSubrole as String && (minimized as? Bool) != true
    }
}
