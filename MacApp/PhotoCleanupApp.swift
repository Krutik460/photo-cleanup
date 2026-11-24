import SwiftUI

@main
struct PhotoCleanupApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Photo Cleanup", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photo Folder…") { model.showAddFolder = true }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Divider()
                Button("Scan for New Photos") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.session == nil || model.isBusy)
                Button("Close Library") { model.closeLibrary() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.session == nil)
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
