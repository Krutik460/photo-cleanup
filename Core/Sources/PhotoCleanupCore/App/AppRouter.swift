import Foundation

/// Answers every request of the interface: `/app/*` from the workspace (folders, scanning, Claude),
/// a library's own requests from the open library's `Router`, and the interface's files.
public final class AppRouter {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// - Parameter range: the request's `Range` header, which a video player sends.
    public func handle(method: String, path: String, body: Data = Data(), range: String? = nil) -> RouterResponse {
        if path.hasPrefix("/app/") { return app(method, String(path.dropFirst("/app/".count)), body) }
        if ["/api/", "/thumb/", "/mid/", "/full/", "/video/"].contains(where: path.hasPrefix) {
            guard let router = workspace.router else { return .error(409, "No folder is open.") }
            return router.handle(method: method, path: path, body: body, range: range)
        }
        guard method == "GET" else { return .error(405, "method not allowed") }
        return Router.staticFile(path, in: workspace.uiDir)
    }

    private func app(_ method: String, _ rest: String, _ body: Data) -> RouterResponse {
        if method == "GET" {
            if rest == "state" { return .json(workspace.state()) }
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count == 3, parts[0] == "thumb", let url = workspace.thumbURL(folder: parts[1], photo: parts[2]) {
                return RouterResponse(contentType: "image/jpeg", file: url, cache: "max-age=3600")
            }
            return .notFound
        }
        guard method == "POST" else { return .error(405, "method not allowed") }
        do {
            var reply = try workspace.perform(rest, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            // Moving the window follows the mouse: no state to send back, and nothing to wait for.
            if rest != "window" { reply["state"] = workspace.state() }
            return .json(reply)
        } catch is CancellationError {
            return .json(["cancelled": true, "state": workspace.state()])
        } catch {
            return .error(400, error.localizedDescription)
        }
    }
}
