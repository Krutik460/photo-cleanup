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

    static func start(_ model: AppModel) {
        if let name = env["PHOTOCLEANUP_OPEN"], let info = model.libraries.first(where: { $0.id == name || $0.name == name }) {
            model.open(info)
        }
        if let folder = env["PHOTOCLEANUP_ADD"] {
            model.addLibrary(photoFolder: URL(fileURLWithPath: folder), photosOfYou: env["PHOTOCLEANUP_ME"].map { [URL(fileURLWithPath: $0)] } ?? [])
        }
        if env["PHOTOCLEANUP_SHOW"] == "add" { model.showAddFolder = true }
        guard let target = env["PHOTOCLEANUP_SNAPSHOT"] else { return }
        let wait = Double(env["PHOTOCLEANUP_SNAPSHOT_AFTER"] ?? "") ?? 4
        Task {
            if env["PHOTOCLEANUP_SNAPSHOT_DURING_SCAN"] == nil {
                while model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
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
        if let sheet = window.attachedSheet, let view = sheet.contentView?.superview ?? sheet.contentView, let rep = picture(view) {
            let name = url.deletingPathExtension().lastPathComponent + "-sheet.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }
}
#endif
