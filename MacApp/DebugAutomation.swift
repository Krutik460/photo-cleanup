#if DEBUG
import AppKit
import WebKit

/// Debug builds only: lets a script drive the app and get a picture of its own window, so the UI can
/// be checked without recording the screen. Controlled by environment variables:
///   PHOTOCLEANUP_LIBRARIES  folder to keep libraries in, instead of Application Support
///   PHOTOCLEANUP_OPEN       name of a library folder to open at launch
///   PHOTOCLEANUP_ADD        photo folder to add and scan at launch (PHOTOCLEANUP_ME: a photo of you)
///   PHOTOCLEANUP_SHOW       "add" shows the Add Photo Folder sheet
///   PHOTOCLEANUP_ROUTE      page route to open once the page has loaded, for example "#review"
///   PHOTOCLEANUP_SNAPSHOT   PNG to write; the app quits afterwards
///   PHOTOCLEANUP_SNAPSHOT_AFTER  seconds to wait before the picture (default 4), counted from when
///                                no scan is running
@MainActor
enum DebugAutomation {
    static let env = ProcessInfo.processInfo.environment

    static func start(_ model: AppModel, openSettings: @escaping () -> Void) {
        // PHOTOCLEANUP_APPEARANCE: "light" or "dark", whatever the system is set to.
        if let name = env["PHOTOCLEANUP_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        // PHOTOCLEANUP_LAUNCH: "skip" goes straight past the opening screen.
        // PHOTOCLEANUP_FAKE_CLAUDE ("missing" or "signedout") replaces what the opening
        // screen is told about the Claude CLI, in this debug process only, so those two cards can be
        // pictured on a Mac that is signed in. It also disables the second opinion in that process.
        if env["PHOTOCLEANUP_LAUNCH"] == "skip" { model.showLaunch = false }
        if let fake = env["PHOTOCLEANUP_FAKE_CLAUDE"] {
            Task {
                while model.claude.checking { try? await Task.sleep(for: .milliseconds(100)) }
                model.claude = fake == "missing"
                    ? ClaudeState(detail: "Not found. Install Claude Code, or choose the command below.", checking: false)
                    : ClaudeState(path: "/usr/local/bin/claude", version: "2.1.330 (Claude Code)", loggedIn: false,
                                  detail: "Not signed in. Run `claude` in Terminal and sign in.", checking: false)
            }
        }
        if let name = env["PHOTOCLEANUP_OPEN"], let info = model.libraries.first(where: { $0.id == name || $0.name == name }) {
            model.open(info)
        }
        if let folder = env["PHOTOCLEANUP_ADD"] {
            model.addLibrary(photoFolder: URL(fileURLWithPath: folder), photosOfYou: env["PHOTOCLEANUP_ME"].map { [URL(fileURLWithPath: $0)] } ?? [])
        }
        if env["PHOTOCLEANUP_SHOW"] == "add" { model.showAddFolder = true }
        if env["PHOTOCLEANUP_SHOW"] == "settings" { openSettings() }
        // PHOTOCLEANUP_OPINION: comma-separated "clear" (forget all picks), "start" (run it), "panel" (open the panel)
        let opinion = Set((env["PHOTOCLEANUP_OPINION"] ?? "").split(separator: ",").map(String.init))
        if opinion.contains("clear") {
            try? model.session?.catalog.clearSecondOpinion()
            model.refreshPending()
        }
        if opinion.contains("panel") { model.showOpinionPanel = true }
        if opinion.contains("start") {
            Task {
                while model.claude.checking { try? await Task.sleep(for: .milliseconds(200)) }
                model.startSecondOpinion()
            }
        }
        guard let target = env["PHOTOCLEANUP_SNAPSHOT"] else { return }
        let wait = Double(env["PHOTOCLEANUP_SNAPSHOT_AFTER"] ?? "") ?? 4
        Task {
            // PHOTOCLEANUP_SNAPSHOT_EARLY: seconds after launch for an extra "<name>-early" picture,
            // taken while work is still running; the app carries on.
            if let early = Double(env["PHOTOCLEANUP_SNAPSHOT_EARLY"] ?? "") {
                try? await Task.sleep(for: .seconds(early))
                let url = URL(fileURLWithPath: target)
                await snapshot(to: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-early.png"))
            }
            if env["PHOTOCLEANUP_SNAPSHOT_DURING_SCAN"] == nil {
                if opinion.contains("start") { try? await Task.sleep(for: .seconds(3)) }
                while model.isBusy || model.opinion != nil || model.claude.checking { try? await Task.sleep(for: .milliseconds(200)) }
            }
            if let route = env["PHOTOCLEANUP_ROUTE"] {
                try? await Task.sleep(for: .seconds(1.5))
                _ = try? await webView()?.evaluateJavaScript("location.hash = \(String(reflecting: route)); null")
            }
            try? await Task.sleep(for: .seconds(wait))
            await snapshot(to: URL(fileURLWithPath: target))
            exit(0)  // not terminate: an open sheet would keep the app running
        }
    }

    static func window() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil && !($0 is NSPanel) }
    }

    static func webView() -> WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let w = view as? WKWebView { return w }
            for sub in view.subviews { if let w = find(sub) { return w } }
            return nil
        }
        return window()?.contentView.flatMap(find)
    }

    /// The whole window, title bar included. Web content is drawn by another process, so it is
    /// pictured separately and placed where the web view is. A sheet is saved next to it as "-sheet".
    static func snapshot(to url: URL) async {
        guard let window = window(), let frame = window.contentView?.superview else { return }
        func picture(_ view: NSView) -> NSBitmapImageRep? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let rep = picture(frame) else { return }
        if let web = webView(), !web.isHidden, web.alphaValue > 0, let page = try? await web.takeSnapshot(configuration: nil) {
            let image = NSImage(size: frame.bounds.size)
            image.addRepresentation(rep)
            image.lockFocus()
            page.draw(in: web.convert(web.bounds, to: frame))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let merged = NSBitmapImageRep(data: tiff) {
                try? merged.representation(using: .png, properties: [:])?.write(to: url)
            }
        } else {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        // Sheets, popovers and the Settings window are windows of their own.
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
