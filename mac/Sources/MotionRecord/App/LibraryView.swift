import SwiftUI
import AVFoundation
import AppKit

struct LibraryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Библиотека").font(.system(size: 20, weight: .semibold))
                    Text(RecordingSession.libraryURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                }
                Spacer()
                Button {
                    try? FileManager.default.createDirectory(at: RecordingSession.libraryURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RecordingSession.libraryURL)
                } label: { Label("Показать в Finder", systemImage: "folder") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { app.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if app.library.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundColor(Theme.textDim)
                    Text("Записей пока нет").font(.system(size: 15, weight: .semibold))
                    Text("Новые записи появятся здесь.").font(.system(size: 12.5)).foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                        ForEach(app.library) { item in
                            LibraryCard(item: item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(24)
        .onAppear { app.refreshLibrary() }
    }
}

private struct LibraryCard: View {
    @EnvironmentObject var app: AppState
    let item: LibraryItem
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        Button { app.openLibraryItem(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color.black
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").font(.system(size: 26)).foregroundColor(Theme.textDim)
                    }
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundColor(.white.opacity(hover ? 0.95 : 0))
                }
                .frame(height: 130).clipped()
                .overlay(alignment: .bottomTrailing) {
                    Text(formatDuration(item.duration))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .padding(8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(item.width)×\(item.height) · \(item.fps) fps · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                        .font(.system(size: 11.5)).foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover ? Color.white.opacity(0.25) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Открыть в редакторе") { app.openLibraryItem(item) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Удалить (в Корзину)", role: .destructive) { app.deleteLibraryItem(item) }
        }
        .task(id: item.url) { thumb = await Self.makeThumbnail(for: item.url.appendingPathComponent("raw.mov")) }
    }

    static func makeThumbnail(for url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        guard let result = try? await gen.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: result.image, size: .zero)
    }
}
