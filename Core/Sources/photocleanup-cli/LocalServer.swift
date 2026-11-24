import Foundation
import Network
import PhotoCleanupCore

/// Serves a Router on 127.0.0.1 so the review page can be opened in a browser while developing.
/// The app itself never listens on a port: it feeds the same Router from a custom URL scheme.
final class LocalServer {
    let router: Router
    let listener: NWListener

    init(router: Router, port: UInt16) throws {
        self.router = router
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [router] connection in
            connection.start(queue: .global())
            Self.read(connection, Data(), router)
        }
        listener.start(queue: .global())
    }

    private static func read(_ connection: NWConnection, _ buffered: Data, _ router: Router) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            var buffer = buffered
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { read(connection, buffer, router) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = head[0].split(separator: " ")
            var length = 0
            for line in head.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let body = buffer[headerEnd.upperBound...]
            if body.count < length, !done, error == nil {
                read(connection, buffer, router)
                return
            }
            guard request.count >= 2 else {
                connection.cancel()
                return
            }
            let path = String(request[1].split(separator: "?")[0]).removingPercentEncoding ?? String(request[1])
            let response = router.handle(method: String(request[0]), path: path, body: Data(body.prefix(length)))
            var status = response.status, payload = response.body
            if let file = response.file {
                if let bytes = try? Data(contentsOf: file) { payload = bytes } else { status = 404; payload = Data() }
            }
            if path.hasPrefix("/api/") { print("\(request[0]) \(path) -> \(status)") }
            let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(response.contentType)\r\n"
                + "Content-Length: \(payload.count)\r\nCache-Control: \(response.cache)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
