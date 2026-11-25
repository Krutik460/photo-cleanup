#if DEBUG
import AppKit
import PhotoCleanupCore
import WebKit

/// Debug builds only: lets a script drive the app and get a picture of its own window, so the UI can
/// be checked without recording the screen. Controlled by environment variables:
///   PHOTOCLEANUP_LIBRARIES  folder to keep libraries in, instead of Application Support
///   PHOTOCLEANUP_OPEN       id of a library folder to open at launch
///   PHOTOCLEANUP_ROUTE      where the page starts, for example "home" or "<id>/c/c3"
///   PHOTOCLEANUP_ADD        photo folder to add and scan at launch (PHOTOCLEANUP_ME: a photo of you)
///   PHOTOCLEANUP_LAUNCH     "skip" goes straight past the opening check
///   PHOTOCLEANUP_FAKE_CLAUDE  "missing" or "signedout": what the page is told about the Claude CLI,
///                           in this process only, so those states can be pictured on a signed-in Mac
///   PHOTOCLEANUP_APPEARANCE "light" or "dark", whatever the system is set to
///   PHOTOCLEANUP_SIZE       window size, for example "1200x800"
///   PHOTOCLEANUP_SHOW       "settings" opens the Settings window
///   PHOTOCLEANUP_OPINION    "start" runs the second opinion
///   PHOTOCLEANUP_JS         a line of the page's script to run before the picture
///   PHOTOCLEANUP_CLICK      "x,y" from the window's top left: a click sent through the window, to
///                           prove that the page gets clicks under the title bar
///   PHOTOCLEANUP_SNAPSHOT   PNG to write; the app quits afterwards
///   PHOTOCLEANUP_SNAPSHOT_AFTER  seconds to wait before the picture (default 4), counted from when
///                           no scan is running. PHOTOCLEANUP_SNAPSHOT_DURING_SCAN: do not wait for it.
///   PHOTOCLEANUP_SNAPSHOT_EARLY  seconds after launch for an extra "<name>-early" picture
@MainActor
enum DebugAutomation {
    static let env = ProcessInfo.processInfo.environment

    nonisolated static func startURL(_ base: URL) -> URL {
        let env = ProcessInfo.processInfo.environment
        var text = base.absoluteString
        if env["PHOTOCLEANUP_LAUNCH"] == "skip" { text += "?launch=skip" }
        if let route = env["PHOTOCLEANUP_ROUTE"] { text += "#" + route } else if let open = env["PHOTOCLEANUP_OPEN"] { text += "#" + open + "/organize" }
        return URL(string: text) ?? base
    }

    static func start(_ model: AppModel, openSettings: @escaping () -> Void) {
        if let name = env["PHOTOCLEANUP_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        if let size = env["PHOTOCLEANUP_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2, let window = NSApp.windows.first {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        // A page in a window that is covered by others stops its timers and animations, and the
        // picture would show them frozen: when a picture is wanted, the window comes to the front.
        // The web view is also told not to watch for being covered (debug builds only, and only here).
        if env["PHOTOCLEANUP_SNAPSHOT"] != nil {
            NSApp.windows.first?.orderFrontRegardless()
            let off = Selector(("_setWindowOcclusionDetectionEnabled:"))
            if let web = model.webView, web.responds(to: off) { web.perform(off, with: nil) }
        }
        let workspace = model.workspace
        if let fake = env["PHOTOCLEANUP_FAKE_CLAUDE"] {
            Task {
                while workspace.claudeState.checking { try? await Task.sleep(for: .milliseconds(100)) }
                workspace.setClaude(fake == "missing"
                    ? Workspace.Claude(detail: "Not installed", checking: false)
                    : Workspace.Claude(path: "/usr/local/bin/claude", version: "2.1.330 (Claude Code)", loggedIn: false,
                                       detail: "Not signed in. Run `claude` in Terminal and sign in.", checking: false))
            }
        }
        if let folder = env["PHOTOCLEANUP_ADD"] {
            let me = env["PHOTOCLEANUP_ME"].map { [URL(fileURLWithPath: $0)] } ?? []
            Task.detached {
                try? workspace.add(folder: URL(fileURLWithPath: folder), photosOfYou: me)
                await MainActor.run { model.page("go(A.open + '/organize')") }
            }
        }
        if env["PHOTOCLEANUP_SHOW"] == "settings" { openSettings() }
        let opinion = env["PHOTOCLEANUP_OPINION"] == "start"
        if opinion {
            Task {
                while workspace.claudeState.checking || !workspace.hasOpenFolder { try? await Task.sleep(for: .milliseconds(200)) }
                try? workspace.startOpinion()
            }
        }
        guard let target = env["PHOTOCLEANUP_SNAPSHOT"] else { return }
        let wait = Double(env["PHOTOCLEANUP_SNAPSHOT_AFTER"] ?? "") ?? 4
        Task {
            if let early = Double(env["PHOTOCLEANUP_SNAPSHOT_EARLY"] ?? "") {
                try? await Task.sleep(for: .seconds(early))
                let url = URL(fileURLWithPath: target)
                await snapshot(to: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-early.png"))
            }
            if env["PHOTOCLEANUP_SNAPSHOT_DURING_SCAN"] == nil {
                try? await Task.sleep(for: .seconds(opinion ? 3 : 1))
                while workspace.isBusy || workspace.state()["opinion"].flatMap({ ($0 as? [String: Any])?["running"] as? Bool }) == true || workspace.claudeState.checking {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            if let script = env["PHOTOCLEANUP_JS"] {
                try? await Task.sleep(for: .seconds(2))
                _ = try? await webView()?.evaluateJavaScript(script + "; null")
            }
            if let click = env["PHOTOCLEANUP_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), click.count == 2 {
                try? await Task.sleep(for: .seconds(1))
                self.click(at: CGPoint(x: click[0], y: click[1]))
            }
            try? await Task.sleep(for: .seconds(wait))
            await snapshot(to: URL(fileURLWithPath: target))
            exit(0)  // not terminate: an open panel would keep the app running
        }
    }

    static func window() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil && !($0 is NSPanel) && webView(in: $0) != nil }
    }

    static func webView(in window: NSWindow? = nil) -> WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let w = view as? WKWebView { return w }
            for sub in view.subviews { if let w = find(sub) { return w } }
            return nil
        }
        return (window ?? self.window())?.contentView.flatMap(find)
    }

    /// A press and release at a point of the window, sent the way the system delivers one.
    static func click(at point: CGPoint) {
        guard let window = window() else { return }
        // A web view ignores presses in a window that is not the key one.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for (i, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.08) {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(event)
                }
            }
        }
    }

    /// The whole window. Web content is drawn by another process, so it is pictured separately and
    /// placed where the web view is, with the traffic lights back on top of it.
    static func snapshot(to url: URL) async {
        guard let window = window(), let frame = window.contentView?.superview else { return }
        func picture(_ view: NSView) -> NSBitmapImageRep? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let rep = picture(frame) else { return }
        if let web = webView(in: window), let page = try? await web.takeSnapshot(configuration: nil) {
            let image = NSImage(size: frame.bounds.size)
            image.addRepresentation(rep)
            image.lockFocus()
            page.draw(in: web.convert(web.bounds, to: frame))
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let light = picture(button) else { continue }
                light.draw(in: button.convert(button.bounds, to: frame))
            }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let merged = NSBitmapImageRep(data: tiff) {
                try? merged.representation(using: .png, properties: [:])?.write(to: url)
            }
        } else {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        // Panels and the Settings window are windows of their own.
        var n = 0
        for other in NSApp.windows where other !== window && other.isVisible {
            guard let view = other.contentView?.superview ?? other.contentView, view.bounds.width > 40, let rep = picture(view) else { continue }
            n += 1
            let name = url.deletingPathExtension().lastPathComponent + "-extra\(n).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }
}
#endif
