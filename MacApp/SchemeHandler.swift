import Foundation
import PhotoCleanupCore
import WebKit

/// Answers the review page's requests inside the app: `photocleanup://app/...` goes to the Router,
/// exactly as `http://localhost/...` did with server.py. Nothing listens on a network port.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "photocleanup"
    static let home = URL(string: "photocleanup://app/")!

    var router: Router?
    private var active = Set<ObjectIdentifier>()  // touched on the main thread only
    private let queue = DispatchQueue(label: "photocleanup.requests", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let request = task.request
        guard let router, let url = request.url else {
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
        // Previews and regrouping take a moment: never on the main thread.
        queue.async {
            var response = router.handle(method: method, path: path, body: body)
            var payload = response.body
            if let file = response.file {
                if let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) {
                    payload = bytes
                } else {
                    response.status = 404
                    payload = Data()
                }
            }
            DispatchQueue.main.async { self.finish(task, id, response, payload) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    /// A task the web view stopped must not be answered: WebKit raises an exception if it is.
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ response: RouterResponse, _ payload: Data) {
        guard active.remove(id) != nil, let url = task.request.url else { return }
        let headers = ["Content-Type": response.contentType, "Content-Length": "\(payload.count)", "Cache-Control": response.cache]
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(http)
        task.didReceive(payload)
        task.didFinish()
    }
}
