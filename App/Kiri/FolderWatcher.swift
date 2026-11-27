import CoreServices
import Foundation

/// Says when something changes on disk anywhere under a folder: a file
/// made, renamed, deleted or written, by Kiri or by anything else (FSEvents).
/// It is told the folders the changes were in, a batch at a time, on a
/// queue of its own; or nil when macOS lost count of them and any folder
/// may have changed.
///
/// Watching ends when the watcher is let go.
nonisolated final class FolderWatcher {
    typealias Handler = @Sendable (_ folders: [String]?) -> Void

    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "se.hellsoft.kiri.folder-watcher")

    /// The handler, kept by the stream for as long as the stream is.
    nonisolated private final class Box: Sendable {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    /// - Parameter latency: how long changes are gathered into one batch
    ///   (the first after a quiet spell comes at once).
    init?(path: String, latency: TimeInterval = 0.3, onChange: @escaping Handler) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(Box(onChange)).toOpaque(),
                                           retain: nil, release: { info in
                                               if let info { Unmanaged<Box>.fromOpaque(info).release() }
                                           }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
            var folders: [String] = []
            for i in 0..<count {
                if flags[i] & lost != 0 { box.handler(nil); return }
                folders.append(String(cString: paths[i]))
            }
            box.handler(folders)
        }
        // (Should it fail, the box is left: a few bytes, once.)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        // (A stream that doesn't start says nothing: the sidebar is as
        // before, with View ▸ Refresh Folder.)
        _ = FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
