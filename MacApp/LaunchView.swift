import AppKit
import SwiftUI

/// The opening screen: the app's mark comes together, then a short check of what the app needs.
/// When the Claude CLI is missing or signed out it shows how to fix that from Terminal. The second
/// opinion is optional, so there is always a way to carry on without it.
struct LaunchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assembled = false
    @State private var showsChecks = false
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            LaunchMark(assembled: assembled)
                .frame(width: 148, height: 132)
            VStack(spacing: 6) {
                Text("Photo Cleanup").font(.system(size: 30, weight: .bold)).tracking(-0.4)
                Text("Keep the best shot. Let the rest go.").font(.title3).foregroundStyle(Theme.secondary)
            }
            .opacity(assembled ? 1 : 0)
            .offset(y: assembled ? 0 : 8)

            VStack(alignment: .leading, spacing: 12) {
                CheckRow(title: "Photo analysis on this Mac", detail: "Similarity, sharpness and faces never leave it", state: .good)
                CheckRow(title: "Face recognition", detail: model.recognisesFaces ? "Ready" : "Not included in this build",
                         state: model.recognisesFaces ? .good : .attention)
                CheckRow(title: "Claude for second opinions", detail: claudeDetail, state: claudeState)
            }
            .frame(width: 420, alignment: .leading)
            .opacity(showsChecks ? 1 : 0)
            .offset(y: showsChecks ? 0 : 10)

            if showsChecks, !model.claude.checking, !model.claude.ready {
                setupCard.transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 10) {
                if !model.claude.checking, !model.claude.ready {
                    Button("Check Again") { model.refreshClaude() }.buttonStyle(QuietButtonStyle())
                }
                Button(model.claude.ready ? "Continue" : "Continue Without Claude") { model.finishLaunch() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .opacity(showsChecks ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(reduceMotion ? nil : Theme.spring, value: model.claude)
        .task {
            if reduceMotion {
                assembled = true
                showsChecks = true
            } else {
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { assembled = true }
                try? await Task.sleep(for: .milliseconds(550))
                withAnimation(Theme.spring) { showsChecks = true }
            }
        }
        // Everything in order: no need to make anyone press a button.
        .task(id: model.claude.ready) {
            guard model.claude.ready, model.recognisesFaces else { return }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 600 : 1500))
            if !Task.isCancelled { model.finishLaunch() }
        }
    }

    private var claudeState: CheckRow.State {
        model.claude.checking ? .checking : (model.claude.ready ? .good : .attention)
    }

    private var claudeDetail: String {
        if model.claude.checking { return "Checking…" }
        guard model.claude.path != nil else { return "Not installed" }
        return model.claude.loggedIn ? "Signed in · \(model.claude.version ?? "Claude CLI")" : "Installed, but not signed in"
    }

    /// How to get there from Terminal. The app shows and copies these commands; it never runs them.
    private var setupCard: some View {
        let installed = model.claude.path != nil
        return VStack(alignment: .leading, spacing: 12) {
            Text(installed ? "Sign in to Claude from Terminal" : "Set up Claude from Terminal")
                .font(.headline)
            Text(installed
                 ? "Run this, then follow the page that opens in your browser. It needs a paid Claude plan or a Console account."
                 : "Install the Claude CLI, then sign in. Each line goes into Terminal. It needs a paid Claude plan or a Console account.")
                .font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !installed { command("curl -fsSL https://claude.ai/install.sh | bash") }
            command("claude auth login")
            HStack(spacing: 14) {
                Button("Open Terminal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                .buttonStyle(.link)
                Link("Setup guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                Spacer()
                Text("Photo Cleanup works without it; only the second opinion needs Claude.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 520, alignment: .leading)
        .card()
    }

    private func command(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
            Spacer()
            Button(copied == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.line))
    }
}

/// One line of the opening check.
struct CheckRow: View {
    enum State { case checking, good, attention }
    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch state {
                case .checking: ProgressView().controlSize(.small)
                case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).transition(.scale.combined(with: .opacity))
                case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn).transition(.scale.combined(with: .opacity))
                }
            }
            .font(.title3)
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }
}

/// The app's mark, drawn live: two repeats fan out behind the keeper and its star lands last.
struct LaunchMark: View {
    let assembled: Bool

    var body: some View {
        ZStack {
            shot(Theme.accent.opacity(0.28)).rotationEffect(.degrees(assembled ? -13 : 0)).offset(x: assembled ? -14 : 0, y: assembled ? -6 : 0)
            shot(Theme.accent.opacity(0.5)).rotationEffect(.degrees(assembled ? 9 : 0)).offset(x: assembled ? 13 : 0, y: assembled ? -7 : 0)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
                .frame(width: 120, height: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.98), Color(red: 0.72, green: 0.86, blue: 1)], startPoint: .top, endPoint: .bottom))
                        .padding(6)
                }
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                .scaleEffect(assembled ? 1 : 0.86)
            Image(systemName: "star.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Theme.gold, in: Circle())
                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 3))
                .offset(x: 54, y: 38)
                .scaleEffect(assembled ? 1 : 0.2)
                .opacity(assembled ? 1 : 0)
        }
    }

    private func shot(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color).frame(width: 112, height: 84)
    }
}
