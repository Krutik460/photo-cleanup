import PhotoCleanupCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.showLaunch {
                LaunchView().transition(.opacity)
            } else if let session = model.session {
                LibraryView(session: session).transition(.opacity)
            } else {
                HomeView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        #if DEBUG
        .task { DebugAutomation.start(model, openSettings: { openSettings() }) }
        #endif
        .sheet(isPresented: $model.showAddFolder) { AddFolderSheet() }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Review imported", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }
}

/// Pick a photo folder and, optionally, a photo of you. Both accept a drop.
struct AddFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var me: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a photo folder").font(.title2.weight(.bold))
                Text("Photos are read where they are. Thumbnails and results are kept in the app's own folder.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }

            DropWell(icon: "folder", title: folder?.lastPathComponent ?? "Choose a photo folder",
                     detail: folder?.deletingLastPathComponent().path ?? "or drop one here", filled: folder != nil) {
                folder = choose(folders: true).first ?? folder
            } onDrop: { urls in
                folder = urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? folder
            }

            VStack(alignment: .leading, spacing: 8) {
                DropWell(icon: "person.crop.square", title: me.isEmpty ? "A photo of you (optional)" : me.map(\.lastPathComponent).joined(separator: ", "),
                         detail: model.recognisesFaces ? (me.isEmpty ? "One to three clear, front-facing photos" : "Click to choose others")
                             : "This build has no face model", filled: !me.isEmpty) {
                    me = choose(folders: false)
                } onDrop: { urls in
                    me = Array(urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }.prefix(3))
                }
                .disabled(!model.recognisesFaces)
                Text("Photos with you are kept more generously. Your face is matched on this Mac and never leaves it.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Add and Scan") {
                    if let folder { model.addLibrary(photoFolder: folder, photosOfYou: me) }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Theme.background)
    }

    private func choose(folders: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = !folders
        if !folders { panel.allowedContentTypes = [.image] }
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// A large target to click or drop onto.
struct DropWell: View {
    let icon: String
    let title: String
    let detail: String
    let filled: Bool
    let action: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var targeted = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: filled ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(filled ? Theme.good : Theme.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(filled ? "Change" : "Choose…").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(targeted ? Theme.accent.opacity(0.1) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: filled ? [] : [7, 6])))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// An open library: the review page, with the scan's progress on top while it runs.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            PageView(router: session.router, version: model.pageVersion)
                .opacity(showsPage ? 1 : 0)
            if !showsPage {
                if let p = model.pipeline {
                    ScanProgressCard(state: p)
                } else {
                    ContentUnavailableView("No photos found", systemImage: "photo",
                                           description: Text("No photos were found in \(session.info.root)."))
                }
            }
        }
        .navigationTitle(session.library.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Theme.spring) { model.closeLibrary() } } label: { Label("All Folders", systemImage: "chevron.backward") }
                    .help("Back to the overview")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let p = model.pipeline, showsPage {
                    HStack(spacing: 8) {
                        ProgressView(value: p.fraction).controlSize(.small).frame(width: 90)
                        Text(p.total > 0 ? "\(p.title) \(p.done.formatted()) of \(p.total.formatted())" : p.title)
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .fixedSize()
                }
                if showsPage { SecondOpinionButton() }
                Button { model.scan() } label: { Label("Scan for New Photos", systemImage: "arrow.clockwise") }
                    .help("Look for new, changed and moved photos in the folder")
                    .disabled(model.isBusy)
            }
        }
    }

    /// The page has nothing to show until the first scan has found photos.
    private var showsPage: Bool { session.catalog.photoCount > 0 }

    private var subtitle: String {
        if let s = model.lastScan, !s.failed.isEmpty { return "\(s.failed.count) files could not be read" }
        if let s = model.lastScan, s.missing > 0 { return "\(s.missing) photos are no longer in the folder" }
        return session.library.isPhotoFolderAvailable ? "" : "Photo folder not connected"
    }
}

/// The first scan of a folder: a ring that fills as photos are analyzed.
struct ScanProgressCard: View {
    @EnvironmentObject var model: AppModel
    let state: PipelineState

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 10)
                Circle().trim(from: 0, to: state.fraction ?? 0.04)
                    .stroke(LinearGradient(colors: [Theme.accent, Theme.good], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.spring, value: state.fraction)
                Text(state.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                if state.fraction == nil { ProgressView() }
            }
            .frame(width: 132, height: 132)
            VStack(spacing: 5) {
                Text(state.title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(Theme.secondary).monospacedDigit()
            }
            Button("Cancel") { model.cancelScan() }.buttonStyle(QuietButtonStyle())
        }
        .padding(36)
        .frame(width: 420)
        .card(padding: 0)
    }

    private var detail: String {
        guard state.total > 0 else { return "Everything is analyzed on this Mac." }
        let failed = state.failed > 0 ? " · \(state.failed) could not be read" : ""
        return "\(state.done.formatted()) of \(state.total.formatted()) photos\(failed)"
    }
}
