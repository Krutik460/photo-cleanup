import PhotoCleanupCore
import SwiftUI
import WebKit

/// The review page (Organize, Review, Finish) in a web view, served by the library's Router.
struct PageView: NSViewRepresentable {
    let router: Router
    /// Changes when the library's data changed outside the page (a scan, a second opinion): reload.
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: SchemeHandler.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")  // no white flash before the page paints
        #if DEBUG
        view.isInspectable = true
        #endif
        context.coordinator.handler.router = router
        context.coordinator.version = version
        view.load(URLRequest(url: SchemeHandler.home))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        if c.handler.router !== router {
            c.handler.router = router
            c.version = version
            view.load(URLRequest(url: SchemeHandler.home))
        } else if c.version != version {
            c.version = version
            view.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = SchemeHandler()
        var version = 0

        /// The page stays inside the app; anything else (there are no such links today) opens in the browser.
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
