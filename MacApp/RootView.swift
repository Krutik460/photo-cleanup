import PhotoCleanupCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                LibraryView(session: session)
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $model.showAddFolder) { AddFolderSheet() }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The start screen: your libraries, and a way to add a photo folder.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Photo Cleanup").font(.largeTitle.weight(.semibold))
                Text("Groups near-identical shots, keeps the best one, and lets you review every decision. Nothing is deleted; files only move when you ask.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.libraries.isEmpty {
                ContentUnavailableView {
                    Label("No photo folder yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add a folder of photos to get started. It is analyzed on this Mac.")
                } actions: {
                    addButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.libraries) { info in
                    Button { model.open(info) } label: { LibraryRow(info: info) }
                        .buttonStyle(.plain)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                HStack {
                    Spacer()
                    addButton
                }
            }
        }
        .buttonBorderShape(.roundedRectangle)
        .padding(32)
        .frame(maxWidth: 760, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .onAppear { model.refreshLibraries() }
    }

    private var addButton: some View {
        Button("Add Photo Folder…") { model.showAddFolder = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

struct LibraryRow: View {
    let info: LibraryInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info.available ? "folder" : "externaldrive.badge.xmark")
                .font(.title2)
                .foregroundStyle(info.available ? Color.accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.headline)
                Text(info.root).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(info.available ? "\(info.photos.formatted()) photos" : "Folder not connected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Pick a photo folder and, optionally, a photo of you.
struct AddFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var me: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a photo folder").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Photo folder").font(.headline)
                HStack {
                    Text(folder?.path ?? "No folder chosen")
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { folder = choose(folders: true).first ?? folder }
                }
                Text("Photos are read where they are. Thumbnails and results are kept in the app's own folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("A photo of you (optional)").font(.headline)
                HStack {
                    Text(me.isEmpty ? "None" : me.map(\.lastPathComponent).joined(separator: ", "))
                        .foregroundStyle(me.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !me.isEmpty { Button("Clear") { me = [] } }
                    Button("Choose…") { me = choose(folders: false) }
                        .disabled(!model.recognisesFaces)
                }
                Text(model.recognisesFaces
                     ? "One to three clear, front-facing photos. Photos with you are kept more generously; your face never leaves this Mac."
                     : "This build has no face model, so photos of you cannot be recognised.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add and Scan") {
                    if let folder { model.addLibrary(photoFolder: folder, photosOfYou: me) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .buttonBorderShape(.roundedRectangle)
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

/// An open library: the review page, with the scan's progress on top while it runs.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        ZStack {
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
                Button { model.closeLibrary() } label: { Label("Libraries", systemImage: "chevron.backward") }
                    .help("Back to your libraries")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let p = model.pipeline, showsPage {
                    HStack(spacing: 8) {
                        ProgressView(value: p.fraction).controlSize(.small).frame(width: 90)
                        Text(p.total > 0 ? "\(p.title) \(p.done.formatted()) of \(p.total.formatted())" : p.title)
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
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

struct ScanProgressCard: View {
    @EnvironmentObject var model: AppModel
    let state: PipelineState

    var body: some View {
        VStack(spacing: 14) {
            Text(state.title).font(.title3.weight(.semibold))
            ProgressView(value: state.fraction)
                .frame(width: 320)
            Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button("Cancel") { model.cancelScan() }
        }
        .buttonBorderShape(.roundedRectangle)
        .padding(28)
    }

    private var detail: String {
        guard state.total > 0 else { return "This takes a moment on a large folder." }
        let failed = state.failed > 0 ? " · \(state.failed) could not be read" : ""
        return "\(state.done.formatted()) of \(state.total.formatted())\(failed)"
    }
}
