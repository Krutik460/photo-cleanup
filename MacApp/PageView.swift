import PhotoCleanupCore
import SwiftUI
import WebKit

/// The whole interface: one page in a web view that fills the window, served by the app itself.
struct PageView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(router: model.router) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: SchemeHandler.scheme)
        // Tells the page it is inside the app: the window is dragged from the page's own toolbar.
        config.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('in-app')",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = DropWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")  // no white flash before the page paints
        #if DEBUG
        view.isInspectable = true
        #endif
        view.onHover = { [weak view] over in view?.evaluateJavaScript("window.appDrop && window.appDrop(\(over)); null") { _, _ in } }
        view.onDrop = { [weak view] folder in
            guard let data = try? JSONEncoder().encode(folder.path), let path = String(data: data, encoding: .utf8) else { return }
            view?.evaluateJavaScript("window.appDropped && window.appDropped(\(path)); null") { _, _ in }
        }
        model.webView = view
        var start = SchemeHandler.home
        #if DEBUG
        start = DebugAutomation.startURL(start)
        #endif
        view.load(URLRequest(url: start))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler: SchemeHandler

        init(router: AppRouter) {
            handler = SchemeHandler(router: router)
        }

        /// The page stays inside the app; anything else opens in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == SchemeHandler.scheme { return .allow }
            if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            return .cancel
        }

        /// The page's keyboard shortcuts need the web view to have focus.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.window?.makeFirstResponder(webView)
        }
    }
}

/// A web view that takes a folder dropped from Finder. A page never learns the path of a dropped
/// file, so the app reads it and hands it over.
final class DropWebView: WKWebView {
    var onHover: ((Bool) -> Void)?
    var onDrop: ((URL) -> Void)?

    private func folder(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folder(sender) != nil else { return [] }
        onHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        folder(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        folder(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = folder(sender) else { return false }
        onDrop?(url)
        return true
    }
}
