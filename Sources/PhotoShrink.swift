import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, uk, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return tr("Як у системі", "System")
        case .uk: return "Українська"
        case .en: return "English"
        }
    }
}

/// True when the UI should be English: chosen in the menu, or the system language isn't Ukrainian.
func isEnglish() -> Bool {
    switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system {
    case .uk: return false
    case .en: return true
    case .system: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("uk")
    }
}

/// Picks the Ukrainian or English string.
func tr(_ uk: String, _ en: String) -> String { isEnglish() ? en : uk }

/// Name of the default output folder; both names are skipped when scanning folders.
func outputFolderName() -> String { tr("Стиснуті", "Compressed") }
let allOutputFolderNames: Set<String> = ["Стиснуті", "Compressed"]

// MARK: - Settings

enum OutputFormat: String, CaseIterable, Identifiable {
    case heic, jpeg, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        case .original: return tr("Як оригінал", "Original")
        }
    }
}

enum OutputLocation: String {
    case nextToOriginal, customFolder
}

struct CompressOptions: Sendable {
    let megapixels: Double
    let format: OutputFormat
    let quality: Double
    let keepMetadata: Bool
    let outputDir: URL?   // nil = output folder next to the original
}

// MARK: - Compression (ImageIO, no third-party code)

enum CompressError: LocalizedError {
    case cannotRead, cannotResize, cannotWrite
    var errorDescription: String? {
        switch self {
        case .cannotRead: return tr("Не вдалося прочитати файл", "Cannot read the file")
        case .cannotResize: return tr("Не вдалося змінити розмір", "Cannot resize the image")
        case .cannotWrite: return tr("Не вдалося зберегти файл", "Cannot save the file")
        }
    }
}

struct CompressResult: Sendable {
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int64
}

enum Compressor {
    struct Info: Sendable {
        let width: Int
        let height: Int
        let bytes: Int64
    }

    /// Reads only the header: pixel size and file size.
    static func info(of url: URL) -> Info? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Info(width: w, height: h, bytes: Int64(size))
    }

    /// Small preview for the list.
    static func thumbnail(of url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // JPEG's embedded EXIF thumbnail is tiny and often letterboxed (Canon adds black bars),
        // so for JPEG decode a downscaled copy (ImageIO does this fast). HEIC/RAW previews are fine.
        let isJPEG = (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier
        let opts: [CFString: Any] = [
            isJPEG ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// - Parameter replacing: a previous result of the same photo that should be replaced.
    static func compress(_ url: URL, options o: CompressOptions, replacing old: URL? = nil) throws -> CompressResult {
        // Frees temporary ImageIO objects right after each photo.
        try autoreleasepool { try compressImpl(url, o, replacing: old) }
    }

    private static func compressImpl(_ url: URL, _ o: CompressOptions, replacing old: URL?) throws -> CompressResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw CompressError.cannotRead }

        // Scale so that width*height ≈ target megapixels. Never upscale.
        let target = max(0.01, o.megapixels) * 1_000_000
        let scale = min(1.0, (target / Double(w * h)).squareRoot())
        let maxSide = max(1, Int((Double(max(w, h)) * scale).rounded()))

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { throw CompressError.cannotResize }

        // Pick output type; fall back to JPEG if the system can't write it (e.g. RAW).
        var typeID: String
        switch o.format {
        case .heic: typeID = UTType.heic.identifier
        case .jpeg: typeID = UTType.jpeg.identifier
        case .original: typeID = (CGImageSourceGetType(src) as String?) ?? UTType.jpeg.identifier
        }
        if !writableTypes.contains(typeID) { typeID = UTType.jpeg.identifier }
        let ext = typeID == UTType.jpeg.identifier ? "jpg" : (UTType(typeID)?.preferredFilenameExtension ?? "jpg")

        // JPEG has no transparency: put transparent images on white instead of black.
        if typeID == UTType.jpeg.identifier { image = flattenedOnWhite(image) }

        // Output path. The file is created right away so parallel jobs never pick the same name.
        let dir = o.outputDir ?? url.deletingLastPathComponent().appendingPathComponent(outputFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old { try? FileManager.default.removeItem(at: old) }
        let outURL = try reserveUniqueURL(in: dir, base: url.deletingPathExtension().lastPathComponent, ext: ext)

        // Metadata: keep EXIF/GPS/etc., but orientation is already applied to the pixels.
        var outProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: o.quality]
        if o.keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let d = props[key] { outProps[key] = d }
            }
            if var tiff = outProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                outProps[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = outProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                outProps[kCGImagePropertyExifDictionary] = exif
            }
        }
        outProps[kCGImagePropertyOrientation] = 1

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, typeID as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: outURL)
            throw CompressError.cannotWrite
        }
        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: outURL)
            throw CompressError.cannotWrite
        }

        let bytes = (try? outURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return CompressResult(url: outURL, width: image.width, height: image.height, bytes: Int64(bytes))
    }

    private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Creates an empty file with a free name ("name.heic", "name (2).heic", …) and returns it.
    /// O_EXCL makes the check-and-create atomic, so two jobs can't grab the same name.
    private static func reserveUniqueURL(in dir: URL, base: String, ext: String) throws -> URL {
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) (\(n))"
            let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o644))
            if fd >= 0 { close(fd); return candidate }
            if errno != EEXIST { throw CompressError.cannotWrite }
            n += 1
        }
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

// MARK: - Model

struct PhotoItem: Identifiable, Sendable {
    enum Status: Sendable { case pending, working, done, failed(String) }
    let id = UUID()
    let url: URL
    let originalBytes: Int64
    let originalMP: Double
    var status: Status = .pending
    var result: CompressResult?

    var isDone: Bool { if case .done = status { return true }; return false }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var scansRunning = 0
    @Published var dropHover = false

    var savedBytes: Int64 {
        items.reduce(0) { sum, item in
            guard let r = item.result else { return sum }
            return sum + (item.originalBytes - r.bytes)
        }
    }

    /// Adds files and folders. Scanning runs in the background so big folders don't freeze the window.
    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        scansRunning += 1
        Task.detached(priority: .userInitiated) {
            var seen = known
            var found: [PhotoItem] = []
            for url in Self.expand(urls) where seen.insert(url).inserted {
                guard let info = Compressor.info(of: url) else { continue }
                found.append(PhotoItem(url: url, originalBytes: info.bytes,
                                       originalMP: Double(info.width * info.height) / 1_000_000))
            }
            await self.append(found)
        }
    }

    private func append(_ found: [PhotoItem]) {
        scansRunning -= 1
        // Another scan may have finished meanwhile, so check for duplicates again.
        let known = Set(items.map(\.url))
        items.append(contentsOf: found.filter { !known.contains($0.url) })
    }

    /// Files are taken as-is; folders are scanned recursively for images.
    nonisolated private static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // skipsPackageDescendants: don't dig into "Photos Library.photoslibrary" and similar.
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if allOutputFolderNames.contains(f.lastPathComponent) { e?.skipDescendants(); continue }
                    if isImage(f) { out.append(f.standardizedFileURL) }
                }
            } else if isImage(url) {
                out.append(url)
            }
        }
        return out
    }

    nonisolated private static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }

    func clear() { if !isProcessing { items.removeAll() } }

    func remove(_ id: UUID) { if !isProcessing { items.removeAll { $0.id == id } } }

    func process(_ options: CompressOptions) {
        guard !isProcessing, !items.isEmpty else { return }
        var todo = items.indices.filter { !items[$0].isDone }
        // Everything is already done: the user changed settings and wants to redo all of them.
        if todo.isEmpty { todo = Array(items.indices) }

        isProcessing = true
        var jobs: [(id: UUID, url: URL, old: URL?)] = []
        for i in todo {
            jobs.append((items[i].id, items[i].url, items[i].result?.url))
            items[i].status = .pending
            items[i].result = nil
        }
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        Task {
            await withTaskGroup(of: (UUID, Result<CompressResult, Error>).self) { group in
                var running = 0
                for job in jobs {
                    if running >= limit, let (doneID, outcome) = await group.next() {
                        apply(doneID, outcome)
                        running -= 1
                    }
                    update(job.id) { $0.status = .working }
                    group.addTask {
                        (job.id, Result { try Compressor.compress(job.url, options: options, replacing: job.old) })
                    }
                    running += 1
                }
                for await (doneID, outcome) in group { apply(doneID, outcome) }
            }
            isProcessing = false
        }
    }

    private func apply(_ id: UUID, _ outcome: Result<CompressResult, Error>) {
        update(id) { item in
            switch outcome {
            case .success(let r): item.result = r; item.status = .done
            case .failure(let e): item.status = .failed(e.localizedDescription)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout PhotoItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }
}

// MARK: - Thumbnails (loaded only for visible rows, cached)

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 500
        return c
    }()

    func load(_ url: URL) async {
        if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
        let cg = await Task.detached(priority: .utility) { Compressor.thumbnail(of: url, maxPixels: 120) }.value
        guard let cg, !Task.isCancelled else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Self.cache.setObject(img, forKey: url as NSURL)
        image = img
    }
}

// MARK: - UI

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

struct ContentView: View {
    @ObservedObject var model = AppModel.shared

    @AppStorage("megapixels") private var megapixels: Double = 12
    @AppStorage("format") private var format: OutputFormat = .heic
    @AppStorage("quality") private var quality: Double = 0.8
    @AppStorage("keepMetadata") private var keepMetadata = true
    @AppStorage("location") private var location: OutputLocation = .nextToOriginal
    @AppStorage("customFolder") private var customFolder: String = ""
    @AppStorage("language") private var language: AppLanguage = .system

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            settings
                .padding(16)
            Divider()
            fileArea
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 580, minHeight: 460)
        .navigationTitle(tr("Стиснення фото", "Photo Compressor"))
        .id(language)   // redraw everything when the language changes
    }

    // Settings panel
    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text(tr("Розмір", "Size")).gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    TextField("", value: $megapixels, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $megapixels, in: 0.5...200, step: 1).labelsHidden()
                    Text(tr("Мп", "MP"))
                    Spacer().frame(width: 8)
                    ForEach([2.0, 5, 8, 12, 24], id: \.self) { mp in
                        Button("\(Int(mp))") { megapixels = mp }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(megapixels == mp ? .accentColor : nil)
                    }
                }
            }
            GridRow {
                Text(tr("Формат", "Format"))
                Picker("", selection: $format) {
                    ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            GridRow {
                Text(tr("Якість", "Quality"))
                HStack {
                    Slider(value: $quality, in: 0.3...1.0, step: 0.05).frame(width: 240)
                    Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .leading)
                }
            }
            GridRow {
                Text(tr("Зберегти в", "Save to"))
                HStack {
                    Picker("", selection: $location) {
                        Text(tr("Папку «Стиснуті» поруч з оригіналом", "“Compressed” folder next to original"))
                            .tag(OutputLocation.nextToOriginal)
                        Text(customFolder.isEmpty ? tr("Вибрану папку…", "Chosen folder…") : URL(fileURLWithPath: customFolder).lastPathComponent)
                            .tag(OutputLocation.customFolder)
                    }
                    .labelsHidden()
                    .frame(width: 300)
                    .onChange(of: location) { newValue in
                        if newValue == .customFolder && customFolder.isEmpty { chooseFolder() }
                    }
                    if location == .customFolder {
                        Button(tr("Змінити…", "Change…")) { chooseFolder() }
                    }
                }
            }
            GridRow {
                Text("")
                Toggle(tr("Зберігати метадані (дата, камера, GPS)", "Keep metadata (date, camera, GPS)"), isOn: $keepMetadata)
            }
        }
        .disabled(model.isProcessing)
    }

    // List / drop zone
    private var fileArea: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(tr("Перетягніть сюди фото або папки", "Drop photos or folders here"))
                        .font(.title3)
                    Button(tr("Вибрати файли…", "Choose files…")) { openFiles() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in
                    PhotoRow(item: item, canRemove: !model.isProcessing, onRemove: { model.remove(item.id) })
                }
                .listStyle(.inset)
            }
        }
        .overlay {
            if model.dropHover {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { hovering in model.dropHover = hovering }
    }

    private var footer: some View {
        HStack {
            Button { openFiles() } label: { Label(tr("Додати", "Add"), systemImage: "plus") }
            Button(tr("Очистити", "Clear")) { model.clear() }
                .disabled(model.items.isEmpty || model.isProcessing)
            if model.scansRunning > 0 {
                ProgressView().controlSize(.small)
                Text(tr("Пошук фото…", "Finding photos…")).foregroundStyle(.secondary)
            }
            Spacer()
            if model.savedBytes > 0 {
                Text(tr("Зекономлено", "Saved") + " " + formatBytes(model.savedBytes))
                    .foregroundStyle(.secondary)
            }
            if model.isProcessing { ProgressView().controlSize(.small) }
            Button(tr("Стиснути", "Compress")) { start() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.items.isEmpty || model.isProcessing || megapixels <= 0)
        }
    }

    private func start() {
        // A number still being typed is only saved when the field loses focus; end editing first,
        // then read the settings on the next run loop pass.
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            guard megapixels > 0 else { return }
            let dir: URL? = (location == .customFolder && !customFolder.isEmpty)
                ? URL(fileURLWithPath: customFolder, isDirectory: true) : nil
            model.process(CompressOptions(megapixels: megapixels, format: format, quality: quality,
                                          keepMetadata: keepMetadata, outputDir: dir))
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = tr("Вибрати", "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            customFolder = url.path
            location = .customFolder
        } else if customFolder.isEmpty {
            location = .nextToOriginal
        }
    }
}

struct PhotoRow: View {
    let item: PhotoItem
    let canRemove: Bool
    let onRemove: () -> Void
    @StateObject private var thumbnail = ThumbnailLoader()

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let r = item.result {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r.url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(tr("Показати у Finder", "Show in Finder"))
            }
            if canRemove {
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("Прибрати зі списку", "Remove from list"))
            }
        }
        .padding(.vertical, 2)
        .task(id: item.url) { await thumbnail.load(item.url) }
    }

    private var details: String {
        let mpUnit = tr("Мп", "MP")
        let before = String(format: "%.1f %@ · %@", item.originalMP, mpUnit, formatBytes(item.originalBytes))
        if case .failed(let msg) = item.status { return "\(before) — \(msg)" }
        guard let r = item.result else { return before }
        let mp = Double(r.width * r.height) / 1_000_000
        let pct = item.originalBytes > 0 ? Int(((1 - Double(r.bytes) / Double(item.originalBytes)) * 100).rounded()) : 0
        let change = pct >= 0 ? "−\(pct)%" : "+\(-pct)%"
        return String(format: "%@  →  %.1f %@ · %@  (%@)", before, mp, mpUnit, formatBytes(r.bytes), change)
    }

    private var thumb: some View {
        ZStack {
            if let image = thumbnail.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) { statusBadge.offset(x: 5, y: 5) }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending: EmptyView()
        case .working:
            ProgressView().controlSize(.mini)
                .padding(3).background(.regularMaterial, in: Circle())
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.system(size: 16))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
                .font(.system(size: 16))
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.add(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.startAutomaticChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quitting mid-way would leave half-written files, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isProcessing else { return .terminateNow }
        let a = NSAlert()
        a.messageText = tr("Стиснення ще триває", "Compression is still running")
        a.informativeText = tr("Якщо вийти зараз, незавершені фото не збережуться.",
                               "If you quit now, unfinished photos won't be saved.")
        a.addButton(withTitle: tr("Вийти", "Quit"))
        a.addButton(withTitle: tr("Скасувати", "Cancel"))
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct PhotoShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("language") private var language: AppLanguage = .system

    var body: some Scene {
        Window("PhotoShrink", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(tr("Перевірити оновлення…", "Check for Updates…")) { Updater.shared.check(userInitiated: true) }
                Divider()
                Picker(tr("Мова", "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}
