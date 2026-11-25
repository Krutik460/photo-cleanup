import SwiftUI

/// The window's content: the page, edge to edge, under a title bar that shows nothing but the
/// traffic lights.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    /// The page's own background, so nothing flashes before it has painted.
    static let pageBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1) : .white
    }

    var body: some View {
        PageView(model: model)
            .ignoresSafeArea()
            .background(WindowChrome())
            .background(Color(nsColor: Self.pageBackground))
            .onAppear {
                model.native.showSettings = { openSettings() }
                #if DEBUG
                DebugAutomation.start(model, openSettings: { openSettings() })
                #endif
            }
    }
}

/// Puts the traffic lights where the page leaves room for them (the first one centred 27 points from
/// the top and the left), and keeps them there: AppKit puts them back whenever the window is resized.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ChromeView: NSView {
        static let barHeight: CGFloat = 54, left: CGFloat = 20, spacing: CGFloat = 20
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.place() }
            }
            // AppKit also lays the title bar out again on its own (a first display, an appearance
            // change): its frame changing is the one signal that covers every case.
            if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
                container.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak self] _ in self?.place() })
            }
            place()
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        private var placing = false

        private func place() {
            guard !placing, let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton), let mini = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton), let container = close.superview?.superview else { return }
            placing = true
            defer { placing = false }
            var frame = container.frame
            frame.size.height = Self.barHeight
            frame.origin.y = window.frame.height - Self.barHeight
            if container.frame != frame { container.frame = frame }
            for (i, button) in [close, mini, zoom].enumerated() {
                let origin = NSPoint(x: Self.left + CGFloat(i) * Self.spacing, y: (Self.barHeight - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
