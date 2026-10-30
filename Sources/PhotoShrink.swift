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

/// True when the UI should be English: chosen in settings, or system language isn't Ukrainian.
func isEnglish() -> Bool {
    switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system {
    case .uk: return false
    case .en: return true
    case .system:
        let preferred = Locale.preferredLanguages.first ?? "en"
        return !preferred.hasPrefix("uk")
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

enum OutputLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, customFolder
    var id: String { rawValue }
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
    static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func compress(_ url: URL, options o: CompressOptions) throws -> CompressResult {
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { throw CompressError.cannotResize }

        // Pick output type.
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        var typeID: String
        switch o.format {
        case .heic: typeID = UTType.heic.identifier
        case .jpeg: typeID = UTType.jpeg.identifier
        case .original: typeID = (CGImageSourceGetType(src) as String?) ?? UTType.jpeg.identifier
        }
        if !writable.contains(typeID) { typeID = UTType.jpeg.identifier }
        let ext: String = {
            if typeID == UTType.jpeg.identifier { return "jpg" }
            return UTType(typeID)?.preferredFilenameExtension ?? "jpg"
        }()

        // Output path.
        let dir = o.outputDir ?? url.deletingLastPathComponent().appendingPathComponent(outputFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = uniqueURL(in: dir, base: url.deletingPathExtension().lastPathComponent, ext: ext)

        // Metadata: keep EXIF/GPS/etc., but orientation is already applied to pixels.
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

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, typeID as CFString, 1, nil)
        else { throw CompressError.cannotWrite }
        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: outURL)
            throw CompressError.cannotWrite
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0
        return CompressResult(url: outURL, width: image.width, height: image.height, bytes: bytes)
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

// MARK: - Model

struct PhotoItem: Identifiable {
    enum Status { case pending, working, done, failed(String) }
    let id = UUID()
    let url: URL
    let originalBytes: Int64
    let originalMP: Double
    var status: Status = .pending
    var result: CompressResult?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var items: [PhotoItem] = []
    @Published var isProcessing = false
    @Published var dropHover = false

    var savedBytes: Int64 {
        items.reduce(0) { sum, item in
            guard let r = item.result else { return sum }
            return sum + (item.originalBytes - r.bytes)
        }
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url })
        for url in expand(urls) where !known.contains(url) {
            guard let (w, h) = Compressor.pixelSize(of: url) else { continue }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            items.append(PhotoItem(url: url, originalBytes: bytes, originalMP: Double(w * h) / 1_000_000))
        }
    }

    /// Files are taken as-is; folders are scanned (recursively) for images.
    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                       options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if allOutputFolderNames.contains(f.lastPathComponent) { e?.skipDescendants(); continue }
                    if isImage(f) { out.append(f) }
                }
            } else if isImage(url) {
                out.append(url)
            }
        }
        return out
    }

    private func isImage(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .image) ?? false
    }

    func clear() { if !isProcessing { items.removeAll() } }

    func remove(_ id: UUID) { if !isProcessing { items.removeAll { $0.id == id } } }

    func process(_ options: CompressOptions) {
        guard !isProcessing else { return }
        let todo = items.indices.filter { if case .done = items[$0].status { return false }; return true }
        guard !todo.isEmpty else { return }
        isProcessing = true
        for i in todo { items[i].status = .pending }

        let jobs = todo.map { (items[$0].id, items[$0].url) }
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        Task { @MainActor in
            await withTaskGroup(of: (UUID, Result<CompressResult, Error>).self) { group in
                var running = 0
                for (id, url) in jobs {
                    if running >= limit, let (doneID, outcome) = await group.next() {
                        self.apply(doneID, outcome)
                        running -= 1
                    }
                    self.setStatus(id, .working)
                    group.addTask { (id, Result { try Compressor.compress(url, options: options) }) }
                    running += 1
                }
                for await (doneID, outcome) in group { self.apply(doneID, outcome) }
            }
            self.isProcessing = false
        }
    }

    private func apply(_ id: UUID, _ outcome: Result<CompressResult, Error>) {
        switch outcome {
        case .success(let r): finish(id, r)
        case .failure(let e): setStatus(id, .failed(e.localizedDescription))
        }
    }

    private func setStatus(_ id: UUID, _ s: PhotoItem.Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }

    private func finish(_ id: UUID, _ r: CompressResult) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].result = r
            items[i].status = .done
        }
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
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

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
        .frame(minWidth: 580, minHeight: 540)
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
                        Text(tr("Папку «Стиснуті» поруч з оригіналом", "“Compressed” folder next to original")).tag(OutputLocation.nextToOriginal)
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
            GridRow {
                Text(tr("Мова", "Language"))
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text(tr("Оновлення", "Updates"))
                HStack(spacing: 12) {
                    Toggle(tr("Перевіряти автоматично", "Check automatically"), isOn: $autoCheckUpdates)
                    Button(tr("Перевірити зараз", "Check now")) { Updater.shared.check(userInitiated: true) }
                        .controlSize(.small)
                    Text("v" + Updater.currentVersion).foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .disabled(model.isProcessing)
    }

    // List / drop zone
    @ViewBuilder
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
                List {
                    ForEach(model.items) { item in
                        PhotoRow(item: item, onRemove: { model.remove(item.id) })
                    }
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
        let dir: URL? = (location == .customFolder && !customFolder.isEmpty)
            ? URL(fileURLWithPath: customFolder, isDirectory: true) : nil
        model.process(CompressOptions(megapixels: megapixels, format: format, quality: quality,
                                      keepMetadata: keepMetadata, outputDir: dir))
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
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 20)
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
            } else if case .working = item.status {
                EmptyView()
            } else {
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("Прибрати зі списку", "Remove from list"))
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        let mpUnit = tr("Мп", "MP")
        let before = String(format: "%.1f %@ · %@", item.originalMP, mpUnit, formatBytes(item.originalBytes))
        switch item.status {
        case .failed(let msg): return "\(before) — \(msg)"
        default: break
        }
        guard let r = item.result else { return before }
        let mp = Double(r.width * r.height) / 1_000_000
        let pct = item.originalBytes > 0 ? Int((1 - Double(r.bytes) / Double(item.originalBytes)) * 100) : 0
        let change = pct >= 0 ? "−\(pct)%" : "+\(-pct)%"
        return String(format: "%@  →  %.1f %@ · %@  (%@)", before, mp, mpUnit, formatBytes(r.bytes), change)
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .pending: Image(systemName: "photo").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Updater.shared.checkOnLaunch() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("PhotoShrink", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(tr("Перевірити оновлення…", "Check for Updates…")) { Updater.shared.check(userInitiated: true) }
            }
        }
    }
}
