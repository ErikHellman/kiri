import AppKit
import KiriKit

#if DEBUG || KIRI_SELFTEST
/// The answer the self-tests give to "Open it read-only?", instead of
/// the alert. Nil asks.
@MainActor enum LargeFileAnswer {
    /// `-KiriLargeFileAnswer YES` (or NO) sets it for a test launch.
    static var forTests: Bool? = UserDefaults.standard.object(forKey: "KiriLargeFileAnswer") == nil ? nil
        : UserDefaults.standard.bool(forKey: "KiriLargeFileAnswer")
}
#endif

/// What the status bar says about a large file.
struct LargeFileStatus: Equatable {
    /// "3.7 GB".
    var size: String
    /// How much of the file the line count has covered, 0 ... 1, while it
    /// is under way; nil once it is done.
    var counting: Double?
}

/// The read-only viewer of one tab's large file: the view, and the work
/// behind it. The lines are counted in the background as soon as the file
/// opens, and the view shows them as they come. A file that grows (a log
/// being written) is followed: what was added is counted, and a view that
/// was at the end stays there. A file that gets shorter (truncated, or
/// rotated by copying and truncating) is opened again. A log rotated by
/// renaming it is followed as any document is, to its new name.
@MainActor final class LargeFileViewer {
    let view: LargeFileView
    private(set) weak var document: KiriDocument?
    private weak var model: EditorModel?
    private var counting: Token?
    private var lastCount = 1
    /// The whole file as it opened has been counted.
    private var countedOnce = false
    private var watch: Timer?
    private let queue = DispatchQueue(label: "se.hellsoft.kiri.large-file", qos: .userInitiated)

    /// Says whether work off the main thread is still wanted.
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    init(document: KiriDocument, file: LargeFile, model: EditorModel) {
        self.document = document
        self.model = model
        view = LargeFileView(file: file)
        view.model = model
        model.large = self
        document.largeViewer = self
        lastCount = file.lineCount
        count()
        // The size is looked at four times a second: a log that is written to
        // isn't always reported as changed.
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            nonisolated(unsafe) let timer = timer
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.fileMayHaveChanged()
            }
        }
    }

    /// The tab is going, or shows another document.
    func stop() {
        counting?.cancel()
        counting = nil
        watch?.invalidate()
        watch = nil
        if model?.large === self {
            model?.large = nil
            // A search of this file, and its matches, end with it.
            model?.find.largeFileGone()
        }
        model?.largeStatus = nil
        if document?.largeViewer === self { document?.largeViewer = nil }
    }

    var file: LargeFile { view.file }

    /// Counts the lines of what hasn't been counted yet.
    private func count() {
        guard counting == nil else { return }
        let token = Token()
        counting = token
        let file = self.file
        publish(counting: file.isIndexed ? nil : Double(file.indexedLength) / Double(max(1, file.size)))
        queue.async { [weak self] in
            file.index(isCancelled: { token.isCancelled }) { progress in
                let fraction = Double(progress.indexedLength) / Double(max(1, progress.size))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !token.isCancelled, self.file === file else { return }
                        self.linesAdded()
                        self.publish(counting: fraction < 1 ? fraction : nil)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.counting === token else { return }
                    self.counting = nil
                    self.linesAdded()
                    self.countedOnce = true
                    self.publish(counting: nil)
                    // It grew while it was being counted. (The once-a-second
                    // look may have seen the new size already.)
                    if file.currentSize > file.indexedLength { self.count() }
                }
            }
        }
    }

    private func linesAdded() {
        let now = file.lineCount
        guard now != lastCount else { return }
        let before = lastCount
        lastCount = now
        // Once counted, lines that come are the file growing: a view at
        // the end follows them.
        view.linesAdded(previousCount: before, following: countedOnce)
        model?.find.largeFileGrew()
    }

    private func publish(counting: Double?) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        let status = LargeFileStatus(size: size, counting: counting)
        if model?.largeStatus != status { model?.largeStatus = status }
    }

    /// The file on disk may have changed (`KiriDocument` was told, or the
    /// once-a-second look).
    func fileMayHaveChanged() {
        switch file.checkSize() {
        case .none: break
        case .grew: count()
        case .shrank: reopen()
        }
    }

    /// Opens the file again, from the top.
    private func reopen() {
        counting?.cancel()
        counting = nil
        guard let url = document?.fileURL, let new = try? LargeFile(url: url) else { return }
        document?.largeFileReopened(new)
        view.replaceFile(new)
        lastCount = new.lineCount
        model?.find.largeFileReplaced()
        count()
    }
}
