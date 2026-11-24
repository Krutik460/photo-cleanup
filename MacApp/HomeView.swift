import AppKit
import PhotoCleanupCore
import SwiftUI
import UniformTypeIdentifiers

/// The overview: what the clean-ups have saved so far, and every photo folder one click away.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false
    @State private var removing: LibraryInfo?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if model.libraries.isEmpty {
                    emptyState
                } else {
                    stats
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your folders").font(.title2.weight(.semibold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(model.libraries) { info in
                                LibraryCard(info: info, open: { model.open(info) }, remove: { removing = info })
                            }
                            AddFolderCard { model.showAddFolder = true }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(background)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        // Drop a folder anywhere on the overview to add it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) else { return false }
            model.addLibrary(photoFolder: folder, photosOfYou: [])
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { model.refreshLibraries() }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Photo Cleanup?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { model.removeLibrary(removing) }
                removing = nil
            }
        } message: {
            Text("Your photos stay exactly where they are. What Photo Cleanup knows about this folder (the analysis, your choices and names) goes to the Trash.")
        }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            Theme.background
            // A quiet wash of the accent behind the header.
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .init(x: 0.18, y: 0), startRadius: 0, endRadius: 560)
                .frame(height: 600)  // taller than the radius, so the wash fades out instead of being cut
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LaunchMark(assembled: true).scaleEffect(0.36).frame(width: 52, height: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("Photo Cleanup").font(.system(size: 26, weight: .bold)).tracking(-0.3)
                Text("Keep the best shot. Let the rest go.").font(.callout).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { openSettings() } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.claude.checking ? Theme.secondary : (model.claude.ready ? Theme.good : Theme.warn)).frame(width: 8, height: 8)
                    Text(model.claude.checking ? "Checking Claude" : (model.claude.ready ? "Claude ready" : "Claude not set up"))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help("Second opinions run through your Claude CLI. Click for settings.")
            Button { model.showAddFolder = true } label: { Label("Add Folder", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("o")
        }
    }

    private var stats: some View {
        let s = model.libraries.compactMap(\.summary)
        let photos = model.libraries.reduce(0) { $0 + $1.photos }
        let removed = s.reduce(0) { $0 + $1.removed }
        let pending = s.reduce(0) { $0 + $1.toRemove }, pendingBytes = s.reduce(0) { $0 + $1.toRemoveBytes }
        let groups = s.reduce(0) { $0 + $1.groups }, reviewed = s.reduce(0) { $0 + $1.reviewedGroups }
        // Five equal columns: the headline number takes two, each of the others one.
        return Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
          GridRow {
            VStack(alignment: .leading, spacing: 6) {
                Label("Space saved", systemImage: "sparkles").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(model.totalSavedBytes.asFileSize)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.good], startPoint: .leading, endPoint: .trailing))
                Text(savedCaption(removed: removed)).font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .card(padding: 22)
            .gridCellColumns(2)

            StatTile(title: "To clean up", value: pending.formatted(), unit: pending == 1 ? "photo" : "photos",
                     caption: pending > 0 ? "Would save another \(pendingBytes.asFileSize)" : "Nothing is waiting", icon: "trash", tint: Theme.warn)
            StatTile(title: "Reviewed", value: groups > 0 ? "\(Int((Double(reviewed) / Double(groups) * 100).rounded()))" : "0", unit: "%",
                     caption: "\(reviewed.formatted()) of \(groups.formatted()) groups of similar shots", icon: "checkmark.seal", tint: Theme.good,
                     progress: groups > 0 ? Double(reviewed) / Double(groups) : nil)
            StatTile(title: "Photos", value: photos.formatted(), unit: "",
                     caption: "in \(model.libraries.count) \(model.libraries.count == 1 ? "folder" : "folders")", icon: "photo.on.rectangle", tint: Theme.accent)
          }
        }
    }

    private func savedCaption(removed: Int) -> String {
        guard removed > 0 else { return "Nothing has been cleaned up yet. Review a folder, then run Clean up on its Finish page." }
        let photos = "\(removed.formatted()) \(removed == 1 ? "photo" : "photos") moved out of your folders"
        let waiting = model.totalWaitingBytes
        return waiting > 0 ? "\(photos). \(waiting.asFileSize) of it is still in _to_remove until you empty those folders." : "\(photos), and gone from disk."
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            LaunchMark(assembled: true).frame(width: 148, height: 132)
            VStack(spacing: 6) {
                Text("Drop a photo folder here").font(.title.weight(.semibold))
                Text("Photo Cleanup finds the near-identical shots in it, keeps the best one of each, and lets you review every decision. Nothing is deleted, and your photos never leave this Mac.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            Button { model.showAddFolder = true } label: { Label("Choose a Folder", systemImage: "folder.badge.plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [8, 7])))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let caption: String
    let icon: String
    let tint: Color
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(unit).font(.title3.weight(.medium)).foregroundStyle(Theme.secondary)
            }
            if let progress {
                Meter(value: progress, tint: tint).padding(.vertical, 2)
            }
            Text(caption).font(.callout).foregroundStyle(Theme.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .card(padding: 22)
    }
}

/// One photo folder: a few of its best photos, how far the review is, and what is left to clean up.
struct LibraryCard: View {
    let info: LibraryInfo
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                CoverMosaic(info: info)
                    .frame(height: 168)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if !info.available {
                            Label("Not connected", systemImage: "externaldrive.badge.xmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(info.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("\(info.photos.formatted()) photos").font(.callout).foregroundStyle(Theme.secondary)
                    }
                    Text((info.root as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    if let s = info.summary, s.groups > 0 {
                        Meter(value: Double(s.reviewedGroups) / Double(s.groups), tint: s.reviewedGroups == s.groups ? Theme.good : Theme.accent)
                        HStack(spacing: 12) {
                            Text("\(s.reviewedGroups.formatted()) of \(s.groups.formatted()) groups reviewed")
                            Spacer()
                            if s.toRemove > 0 {
                                Label("\(s.toRemove.formatted()) · \(s.toRemoveBytes.asFileSize)", systemImage: "trash").foregroundStyle(Theme.warn)
                            } else if s.removedBytes > 0 {
                                Label("\(s.removedBytes.asFileSize) saved", systemImage: "checkmark.circle").foregroundStyle(Theme.good)
                            }
                        }
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    } else {
                        Text(info.photos == 0 ? "Not scanned yet" : "No groups of similar shots").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(16)
            }
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.line))
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 18 : 8, y: hovering ? 8 : 3)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hovering = h } }
        .contextMenu {
            Button("Open", action: open)
            Button("Show Photo Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.root)]) }
                .disabled(!info.available)
            Divider()
            Button("Remove from Photo Cleanup…", role: .destructive, action: remove)
        }
        .accessibilityLabel("\(info.name), \(info.photos) photos")
    }
}

/// Up to four of a library's best photos: one large, the rest stacked beside it.
struct CoverMosaic: View {
    let info: LibraryInfo

    var body: some View {
        let images = (info.summary?.covers ?? []).prefix(4).compactMap { id in
            info.thumbsDir.flatMap { NSImage(contentsOf: $0.appendingPathComponent("\(id).jpg")) }
        }
        GeometryReader { geo in
            if images.isEmpty {
                ZStack {
                    LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "photo.stack").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.secondary)
                }
            } else if images.count == 1 {
                tile(images[0], geo.size.width, geo.size.height)
            } else {
                let side = geo.size.width * 0.34
                HStack(spacing: 2) {
                    tile(images[0], geo.size.width - side - 2, geo.size.height)
                    VStack(spacing: 2) {
                        let rest = Array(images.dropFirst())
                        let h = (geo.size.height - CGFloat(rest.count - 1) * 2) / CGFloat(rest.count)
                        ForEach(rest.indices, id: \.self) { tile(rest[$0], side, h) }
                    }
                }
            }
        }
    }

    private func tile(_ image: NSImage, _ w: CGFloat, _ h: CGFloat) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: max(w, 1), height: max(h, 1)).clipped()
    }
}

struct AddFolderCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 26, weight: .semibold))
                Text("Add a photo folder").font(.headline)
                Text("or drop one anywhere here").font(.callout).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(hovering ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 278)
            .background(Theme.surface.opacity(hovering ? 1 : 0.5), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(hovering ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hovering = h } }
    }
}
