import AppKit
import PhotoCleanupCore
import SwiftUI
import WebKit

enum Preferences {
    static let claudePath = "claudePath"
    static let claudeModel = "claudeModel"
    static let claudeParallel = "claudeParallel"
    static let checkForUpdates = "checkForUpdates"
    static let updateMemory = "updateMemory"

    static var model: String { UserDefaults.standard.string(forKey: claudeModel) ?? "haiku" }
    static var parallel: Int { max(1, min(6, UserDefaults.standard.object(forKey: claudeParallel) as? Int ?? 3)) }
}

/// The native side of the app. The interface is one web page (the `ui` folder); everything it shows
/// comes from the `Workspace`, which this class owns and connects to the Mac: menus, pickers, Finder,
/// the Settings window and the window itself.
@MainActor
final class AppModel: ObservableObject {
    let workspace: Workspace
    let router: AppRouter
    let native = NativeUI()

    /// What the menus and the Settings window need to know.
    @Published var claude = Workspace.Claude()
    @Published var hasOpenFolder = false
    @Published var isBusy = false

    weak var webView: WKWebView?
    private var notifyScheduled = false

    static let releaseIdentifier = "local.photocleanup.app"

    var librariesDir: URL { workspace.librariesDir }
    let recognisesFaces: Bool

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // ~/Library/Application Support/Photo Cleanup/Libraries, one folder per photo folder. A copy of
        // the app built under another identifier (a development copy next to the installed app) keeps
        // its libraries under that identifier, so it can never open or change the real ones.
        let id = Bundle.main.bundleIdentifier ?? AppModel.releaseIdentifier
        let home = id == AppModel.releaseIdentifier ? "Photo Cleanup" : id
        let libraries = ProcessInfo.processInfo.environment["PHOTOCLEANUP_LIBRARIES"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("\(home)/Libraries")
        // Previews and Core ML's compiled model are caches: they live where macOS may reclaim them.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(id)
        if ProcessInfo.processInfo.environment["PHOTOCLEANUP_LIBRARIES"] == nil { Library.previewsRoot = caches.appendingPathComponent("Previews") }
        // Face recognition model inside the app; nil when the app was built without it.
        let model = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc")
        if let model { trimCompiledModelCache(in: caches, model: model) }
        let embedder = model.flatMap { try? CoreMLFaceEmbedder(compiledModelAt: $0) }
        recognisesFaces = embedder != nil
        var ui = Bundle.main.resourceURL!.appendingPathComponent("ui")
        #if DEBUG
        // Development: the interface straight from the source folder, so a change needs no rebuild.
        if let dev = ProcessInfo.processInfo.environment["PHOTOCLEANUP_UI"] { ui = URL(fileURLWithPath: dev) }
        #endif
        workspace = Workspace(librariesDir: libraries, uiDir: ui, embedder: embedder)
        router = AppRouter(workspace: workspace)
        workspace.claudePath = { UserDefaults.standard.string(forKey: Preferences.claudePath) }
        workspace.claudeModel = { Preferences.model }
        workspace.claudeParallel = { Preferences.parallel }
        workspace.ui = native
        workspace.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        workspace.updatesEnabled = { UserDefaults.standard.object(forKey: Preferences.checkForUpdates) as? Bool ?? true }
        workspace.loadUpdateMemory = { UserDefaults.standard.data(forKey: Preferences.updateMemory).flatMap { try? JSONDecoder().decode(UpdateMemory.self, from: $0) } }
        workspace.saveUpdateMemory = { UserDefaults.standard.set(try? JSONEncoder().encode($0), forKey: Preferences.updateMemory) }
        workspace.onChange = { [weak self] in
            DispatchQueue.main.async { self?.workspaceChanged() }
        }
        workspace.refreshClaude()
        // Once a day at most, and again when the app comes back to the front after a day.
        workspace.checkForUpdate()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [workspace] _ in
            workspace.checkForUpdate()
        }
    }

    /// The workspace reports every step of a scan; the page and the menus hear about it a few times a second.
    private func workspaceChanged() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.claude = self.workspace.claudeState
            self.hasOpenFolder = self.workspace.hasOpenFolder
            self.isBusy = self.workspace.isBusy
            self.update = self.workspace.state()["update"] as? [String: Any] ?? [:]
            self.page("window.appChanged && window.appChanged()")
        }
    }

    /// Runs a line of the page's own script: how menu commands reach the interface.
    func page(_ script: String) {
        webView?.evaluateJavaScript(script + "; null") { _, _ in }
    }

    func refreshClaude() { workspace.refreshClaude() }

    /// What Settings says about updates.
    @Published var update: [String: Any] = [:]
    func checkForUpdate() { workspace.checkForUpdate(force: true) }

    func scan() { workspace.startScan() }

    /// Brings the review done with the earlier scripts into the open folder. The picker and the
    /// import both run off the main thread; the page shows what was imported.
    func importOldReview() {
        let workspace = workspace
        Task.detached {
            do {
                try workspace.importOldReview(from: nil)
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "The old review could not be imported"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }
}

/// What the page asks the Mac to do. Called on the thread that answers the page's request, never the
/// main thread, so each call hops there.
final class NativeUI: WorkspaceUI {
    /// Set by the window once SwiftUI can open Settings.
    var showSettings: (() -> Void)?
    /// The mouse press a window drag starts from.
    private var lastMouseDown: NSEvent?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.lastMouseDown = event
            return event
        }
    }

    func choose(_ kind: String) -> [URL] {
        DispatchQueue.main.sync {
            let panel = NSOpenPanel()
            switch kind {
            case "me":
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.image]
                panel.message = "Choose one to three clear photos of you"
                panel.prompt = "Choose"
            case "old-review":
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.message = "Choose the output folder of the old photo cleanup scripts (the one with analysis.jsonl)"
                panel.prompt = "Import"
            default:
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.message = "Choose a folder of photos. Nothing in it changes until you ask."
                panel.prompt = "Choose"
            }
            guard panel.runModal() == .OK else { return [] }
            return Array(panel.urls.prefix(kind == "me" ? 3 : 1))
        }
    }

    func reveal(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func openSettings() {
        DispatchQueue.main.async { self.showSettings?() }
    }

    func open(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    func openTerminal() {
        DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
    }

    /// The page draws its own toolbar, so it tells the app when a press there should move the window.
    func window(_ action: String) {
        DispatchQueue.main.async {
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
            if action == "zoom" {
                window.zoom(nil)
            } else if let event = self.lastMouseDown, event.window === window, NSEvent.pressedMouseButtons & 1 == 1 {
                window.performDrag(with: event)
            }
        }
    }
}
