#if DEBUG || KIRI_SELFTEST
import AppKit
import ImageIO
import KiriKit
import UniformTypeIdentifiers

extension SelfTest {
    /// A picture, a video or an archive showed in a tab for the first time.
    /// (`-KiriZoom <percent>` zooms a picture, for a screenshot.)
    static func mediaShown(_ tab: DocumentTab) {
        guard let percent = UserDefaults.standard.string(forKey: "KiriZoom").flatMap(Double.init),
              let image = tab.mediaViewer?.contentForTests as? ImageViewer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            _ = image.zoom(.actualSize)
            let steps = Int((log(percent / 100) / log(1.25)).rounded())
            for _ in 0..<abs(steps) { _ = image.zoom(steps > 0 ? .bigger : .smaller) }
        }
    }

    /// The viewers (`MediaViewer`): a PNG, an animated GIF, a zip, a
    /// tar.gz, an SVG and (with `-KiriViewerVideo <file>`) a video open
    /// read-only in their viewers instead of the editor, with what they are
    /// in the status bar; nothing saves them; ⌘+ zooms a picture; the GIF
    /// plays; the archives list their files with their sizes; find has
    /// nothing to find in them; a text file called .png opens as text; and
    /// AVKit and the video player load only when the video opens.
    /// `-KiriViewerTest YES` runs these, in a launch with any small file.
    static func viewerStage() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-viewers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func open(_ url: URL) async -> KiriDocument? {
            await withCheckedContinuation { done in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
                    done.resume(returning: document as? KiriDocument)
                }
            }
        }
        func status(_ tab: DocumentTab) -> String { tab.model.mediaStatus?.text ?? "" }
        func waitFor(_ ms: Int = 4000, _ condition: () -> Bool) async {
            for _ in 0..<(ms / 50) where !condition() { await settle(50) }
        }
        let save = NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "")

        // Nothing of the video player is loaded at launch.
        report(!VideoPlugin.isLoaded && NSClassFromString("AVPlayerView") == nil,
               "the video player and AVKit aren't loaded at launch")

        // A PNG, 40 × 30.
        let png = folder.appendingPathComponent("picture.png")
        guard writeImage(to: png, type: .png, frames: [.systemRed]) else { report(false, "a PNG to open"); return }
        guard let pngDoc = await open(png), let pngTab = DocumentWindow.tab(of: pngDoc) else {
            report(false, "a PNG opens"); return
        }
        await waitFor { status(pngTab).contains("40 × 30") }
        report(pngDoc.media?.kind == .image("PNG") && pngDoc.isReadOnly && pngDoc.text.isEmpty, "a PNG opens as a picture")
        report(pngTab.mediaViewer?.view.window != nil && pngTab.container.superview == nil,
               "a picture shows in its viewer, not the editor")
        report(status(pngTab).hasPrefix("PNG · 40 × 30 · 100%"), "the status bar says what the picture is (\(status(pngTab)))")
        report(!pngDoc.validateUserInterfaceItem(save), "a picture can't be saved")
        if let image = pngTab.mediaViewer?.contentForTests as? ImageViewer {
            FrontEditor.shared.selfTestMain(pngTab.window ?? NSWindow())
            let before = image.magnification
            let zoomed = EditAction.zoomMedia(.bigger)
            report(zoomed && image.magnification > before, "⌘+ zooms a picture (\(before) → \(image.magnification))")
            _ = EditAction.zoomMedia(.actualSize)
            report(abs(image.magnification - 1) < 0.01, "⌘0 shows a picture at its actual size")
        } else {
            report(false, "a picture has the image viewer")
        }
        // Find has no text to find in.
        EditAction.find(.show)
        await settle()
        report(!pngTab.model.find.isOpen, "find doesn't open on a picture")

        // An animated GIF of three frames: it plays.
        let gif = folder.appendingPathComponent("animated.gif")
        guard writeImage(to: gif, type: .gif, frames: [.systemRed, .systemGreen, .systemBlue]) else {
            report(false, "a GIF to open"); return
        }
        guard let gifDoc = await open(gif), let gifTab = DocumentWindow.tab(of: gifDoc) else { report(false, "a GIF opens"); return }
        await waitFor { status(gifTab).contains("3 frames") }
        report(status(gifTab).contains("3 frames"), "an animated GIF says its frames (\(status(gifTab)))")
        let gifViewer = gifTab.mediaViewer?.contentForTests as? ImageViewer
        await waitFor { (gifViewer?.framesShown ?? 0) > 3 }
        report((gifViewer?.framesShown ?? 0) > 3, "an animated GIF plays (\(gifViewer?.framesShown ?? 0) frames shown)")

        // A zip and a tar.gz of the same folder.
        let source = folder.appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: source.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? Data(repeating: 0x61, count: 1500).write(to: source.appendingPathComponent("README.md"))
        try? Data(repeating: 0x62, count: 2500).write(to: source.appendingPathComponent("src/main.swift"))
        let zip = folder.appendingPathComponent("project.zip")
        let tgz = folder.appendingPathComponent("project.tar.gz")
        // (Without the AppleDouble "._" files that carry extended attributes.)
        run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", source.path, zip.path])
        run("/usr/bin/tar", ["--no-mac-metadata", "-czf", tgz.path, "-C", folder.path, "project"])
        for (url, name) in [(zip, "ZIP"), (tgz, "TAR.GZ")] {
            guard let doc = await open(url), let tab = DocumentWindow.tab(of: doc),
                  let archive = tab.mediaViewer?.contentForTests as? ArchiveViewer else {
                report(false, "a \(name) opens in the archive viewer"); continue
            }
            await waitFor { archive.tree != nil }
            let tree = archive.tree
            report(tree?.fileCount == 2 && tree?.totalSize == 4000,
                   "a \(name) lists its files and their size unpacked (\(tree?.fileCount ?? 0) files, \(tree?.totalSize ?? 0) bytes)")
            // The one folder at the top is open; src is closed until clicked.
            let names = archive.rows.map(\.node.name)
            report(names == ["project", "src", "README.md"], "a \(name) opens its one folder (\(names))")
            if let src = archive.rows.first(where: { $0.node.name == "src" })?.node { archive.toggle(src) }
            report(archive.rows.map(\.node.name) == ["project", "src", "main.swift", "README.md"], "a click opens a folder of a \(name)")
            report(status(tab).hasPrefix("\(name) · 2 files · 4 KB unpacked"), "the status bar says what the \(name) holds (\(status(tab)))")
            report(!doc.validateUserInterfaceItem(save), "a \(name) can't be saved")
        }

        // An SVG opens on its picture, and switches to its text.
        let svg = folder.appendingPathComponent("drawing.svg")
        try? Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\"><rect width=\"40\" height=\"30\" fill=\"red\"/></svg>\n".utf8)
            .write(to: svg)
        if let doc = await open(svg), let tab = DocumentWindow.tab(of: doc) {
            await waitFor { tab.markdownPreview?.isReady == true && tab.markdownPreview?.webView.window != nil }
            report(doc.media == nil && !doc.isReadOnly && tab.showsMarkdownPreview && tab.markdownPreview?.webView.window != nil,
                   "an SVG opens on its picture")
            tab.setMarkdownPreview(false)
            await settle()
            report(tab.container.superview != nil && tab.controller.textView?.string.hasPrefix("<svg") == true,
                   "an SVG's text is a switch away")
        } else {
            report(false, "an SVG opens")
        }

        // Text, whatever it is called, opens as text.
        let fake = folder.appendingPathComponent("notes.png")
        try? Data("not a picture\n".utf8).write(to: fake)
        if let doc = await open(fake), let tab = DocumentWindow.tab(of: doc) {
            report(doc.media == nil && tab.mediaViewer == nil && doc.text == "not a picture\n", "a text file called .png opens as text")
        } else {
            report(false, "a text file called .png opens")
        }

        // Still nothing of the video player.
        report(!VideoPlugin.isLoaded && NSClassFromString("AVPlayerView") == nil,
               "pictures, archives and SVG don't load the video player or AVKit")

        // A video, when one is given.
        if let path = UserDefaults.standard.string(forKey: "KiriViewerVideo") {
            let url = URL(fileURLWithPath: path)
            if let doc = await open(url), let tab = DocumentWindow.tab(of: doc), let video = tab.mediaViewer?.contentForTests as? VideoViewer {
                await waitFor(8000) { status(tab).contains(":") }
                report(VideoPlugin.isLoaded && NSClassFromString("AVPlayerView") != nil && video.playerView?.window != nil,
                       "a video loads the player and shows in it")
                report(status(tab).contains(":"), "the status bar says the video's size and length (\(status(tab)))")
                report(!doc.validateUserInterfaceItem(save), "a video can't be saved")
            } else {
                report(false, "a video opens in the video viewer")
            }
        } else {
            print("SELFTEST info no -KiriViewerVideo given: the video isn't checked")
        }

        for document in NSDocumentController.shared.documents where (document.fileURL?.path ?? "").hasPrefix(folder.path) {
            document.close()
        }
        await settle(200)
    }

    /// Writes a 40 × 30 picture, one frame of each color (a GIF of several plays).
    private static func writeImage(to url: URL, type: UTType, frames: [NSColor]) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil)
        else { return false }
        if frames.count > 1 {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                as CFDictionary)
        }
        for color in frames {
            guard let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            guard let image = context.makeImage() else { return false }
            let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary
            CGImageDestinationAddImage(destination, image, frames.count > 1 ? delay : nil)
        }
        return CGImageDestinationFinalize(destination)
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["COPYFILE_DISABLE": "1"]
        try? process.run()
        process.waitUntilExit()
    }
}
#endif
