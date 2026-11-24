import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Preferences.claudePath) private var claudePath = ""
    @AppStorage(Preferences.claudeModel) private var claudeModel = "haiku"
    @AppStorage(Preferences.claudeParallel) private var parallel = 3

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if model.claude.checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: model.claude.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.claude.ready ? .green : .orange)
                        }
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Command") {
                    HStack {
                        Text(model.claude.path ?? (claudePath.isEmpty ? "Not found" : claudePath))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { choose() }
                        if !claudePath.isEmpty {
                            Button("Find Automatically") {
                                claudePath = ""
                                model.refreshClaude()
                            }
                        }
                    }
                }
                Picker("Model", selection: $claudeModel) {
                    Text("Haiku (fast, low cost)").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                Stepper("Batches at a time: \(parallel)", value: $parallel, in: 1...6)
            } header: {
                Text("Second opinion")
            } footer: {
                Text("The second opinion runs your installed Claude CLI with your Claude sign-in. No API key is stored in this app.")
                    .foregroundStyle(.secondary)
            }

            Section("On this Mac") {
                LabeledContent("Face recognition", value: model.recognisesFaces ? "Included" : "Not included in this build")
                LabeledContent("Libraries") {
                    HStack {
                        Text(model.librariesDir.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.librariesDir]) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .buttonBorderShape(.roundedRectangle)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshClaude() }
    }

    private var statusText: String {
        if model.claude.checking { return "Checking…" }
        guard model.claude.path != nil else { return model.claude.detail }
        return [model.claude.version, model.claude.detail].compactMap { $0 }.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the claude command"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            claudePath = url.path
            model.refreshClaude()
        }
    }
}
