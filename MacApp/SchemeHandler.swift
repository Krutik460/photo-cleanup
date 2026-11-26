import Foundation
import PhotoCleanupCore
import WebKit

/// Answers the page's requests inside the app: `photocleanup://app/...` goes to the AppRouter, as
/// `http://localhost/...` does with the development server. Nothing listens on a network port.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "photocleanup"
    static let home = URL(string: "photocleanup://app/")!

    let router: AppRouter
    private var active = Set<ObjectIdentifier>()  // touched on the main thread only
    private let queue = DispatchQueue(label: "photocleanup.requests", qos: .userInitiated, attributes: .concurrent)

    init(router: AppRouter) {
        self.router = router
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let request = task.request
        guard let url = request.url else {
            finish(task, id, RouterResponse(status: 503), Data())
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let method = request.httpMethod ?? "GET", path = url.path.isEmpty ? "/" : url.path
        let range = request.value(forHTTPHeaderField: "Range")  // a video is played in parts
        // Previews and regrouping take a moment: never on the main thread.
        queue.async { [router] in
            var response = router.handle(method: method, path: path, body: body, range: range)
            var payload = Data()
            if let bytes = response.payload() { payload = bytes } else { response.status = 404 }
            DispatchQueue.main.async { self.finish(task, id, response, payload) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    /// A task the web view stopped must not be answered: WebKit raises an exception if it is.
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ response: RouterResponse, _ payload: Data) {
        guard active.remove(id) != nil, let url = task.request.url else { return }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers(length: payload.count)) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(http)
        task.didReceive(payload)
        task.didFinish()
    }
}
