import SwiftUI

@main
struct PhotoCleanupApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Photo Cleanup", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photo Folder…") { model.page("addFolder()") }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Divider()
                Button("Scan for New Photos") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(!model.hasOpenFolder || model.isBusy)
                Button("Import Review from the Old Scripts…") { model.importOldReview() }
                    .disabled(!model.hasOpenFolder || model.isBusy)
                Button("All Folders") { model.page("go('home')") }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasOpenFolder)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.page("openHelp()") }
                    .disabled(!model.hasOpenFolder)
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
