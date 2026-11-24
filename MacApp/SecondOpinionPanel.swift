import PhotoCleanupCore
import SwiftUI

/// The toolbar's second-opinion control: a button that opens a panel to start, follow and stop the run.
struct SecondOpinionButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.showOpinionPanel.toggle() } label: {
            if let p = model.opinion {
                HStack(spacing: 6) {
                    ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : nil).controlSize(.small).frame(width: 60)
                    Text(p.total > 0 ? "\(p.done) of \(p.total)" : "Starting").monospacedDigit()
                }
            } else {
                Label("Second Opinion", systemImage: "sparkles")
            }
        }
        .help("Ask Claude which shots of each group to keep")
        .popover(isPresented: $model.showOpinionPanel, arrowEdge: .bottom) { SecondOpinionPanel().environmentObject(model) }
    }
}

struct SecondOpinionPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Second opinion").font(.headline)
                Text("Claude looks at each group of similar shots and suggests which to keep. Its picks show up in the review, and your own choices always win.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let p = model.opinion {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : nil)
                    Text(progressText(p)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Label(pendingText, systemImage: model.pendingGroups > 0 ? "square.stack.3d.up" : "checkmark.circle")
                    .font(.callout)
            }

            if !model.opinionLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.opinionLog.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.opinionLog.count) { proxy.scrollTo(model.opinionLog.count - 1, anchor: .bottom) }
                }
            }

            Divider()

            Label {
                Text("Small contact sheets of these photos are sent to Anthropic through your Claude CLI. File names, locations and face data stay on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: model.claude.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.claude.ready ? .green : .orange)
                Text(claudeText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.opinion != nil {
                    Button("Stop") { model.cancelSecondOpinion() }
                } else if model.claude.ready {
                    if model.pendingGroups > 0 {
                        Button(model.pendingGroups == 1 ? "Ask About 1 Group" : "Ask About \(model.pendingGroups.formatted()) Groups") { model.startSecondOpinion() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                    }
                } else {
                    Button("Settings…") { openSettings() }
                }
            }
        }
        .buttonBorderShape(.roundedRectangle)
        .padding(16)
        .frame(width: 400)
    }

    private var pendingText: String {
        switch model.pendingGroups {
        case 0: "Every group has a second opinion."
        case 1: "1 group has not been looked at yet."
        default: "\(model.pendingGroups.formatted()) groups have not been looked at yet."
        }
    }

    private func progressText(_ p: SecondOpinionRun.Progress) -> String {
        guard p.total > 0 else { return "Preparing contact sheets" }
        let failed = p.failed > 0 ? " · \(p.failed) failed" : ""
        return "\(p.done) of \(p.total) batches · \(p.groups.formatted()) groups looked at\(failed)"
    }

    private var claudeText: String {
        if model.claude.checking { return "Looking for the Claude CLI…" }
        guard model.claude.path != nil else { return "Claude CLI not found" }
        return model.claude.loggedIn ? "Claude CLI \(model.claude.version ?? "")" : model.claude.detail
    }
}
