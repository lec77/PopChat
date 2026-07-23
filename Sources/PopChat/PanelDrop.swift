import SwiftUI
import AppKit

/// AppKit drop target spanning the whole panel.
///
/// SwiftUI's `.dropDestination(for: URL.self)` was here first and only accepts
/// drags that already carry a file URL. The macOS screenshot thumbnail (and
/// Photos, Mail attachments) drags a FILE PROMISE instead: the PNG doesn't
/// exist on disk yet — the destination hands the source a directory and only
/// then is the file written — so the old handler ignored exactly the "drag a
/// fresh screenshot in" case. AppKit is the layer that can read
/// `NSFilePromiseReceiver`s off the drag pasteboard, and
/// `NSFilePromiseReceiver.readableDraggedTypes` is the documented registration
/// list, so nothing here guesses type strings. Raw image data (a browser image
/// drag) is the last fallback, mirroring what ⌘V paste already does.
///
/// Routing order in `handleDrop` is a law: file URLs BEFORE promises — sources
/// that offer both would otherwise be copied through the temp dir for nothing,
/// and the promise copy happens before the loader can enforce its size cap —
/// and image data only when neither is present (a Finder drag can carry the
/// file's icon as image data; matching images first would attach the icon).
final class PanelDropView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onFileURLs: (([URL]) -> Void)?
    var onImage: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?
    /// Where the last promise drop is being written; read by `--smoke-drop`
    /// (in-process promise RESOLUTION can't be simulated — the pasteboard
    /// server never calls a source back inside its own process — so the
    /// harness verifies the receive was initiated).
    private(set) var lastPromiseDestination: URL?

    /// Promised-file reader blocks land here; Apple documents the main queue
    /// as the wrong place (the copy can take as long as the source needs).
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PopChat.drop-promises"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promiseTypes + [.tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        return handleDrop(from: sender.draggingPasteboard)
    }

    func accepts(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || NSImage.canInit(with: pasteboard)
    }

    func handleDrop(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onFileURLs?(urls)
            return true
        }
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receive(receivers)
            return true
        }
        if let image = NSImage(pasteboard: pasteboard) {
            onImage?(image)
            return true
        }
        return false
    }

    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopChat-drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            onError?("Couldn't receive the dropped file: \(error.localizedDescription)")
            return
        }
        lastPromiseDestination = destination
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.onError?("Couldn't receive the dropped file: \(error.localizedDescription)")
                    } else {
                        self?.onFileURLs?([url])
                    }
                }
            }
        }
    }
}

struct PanelDropCatcher: NSViewRepresentable {
    @Binding var targeted: Bool
    let model: ComposerModel

    func makeNSView(context: Context) -> PanelDropView {
        let view = PanelDropView()
        wire(view)
        return view
    }

    func updateNSView(_ view: PanelDropView, context: Context) {
        wire(view)
    }

    private func wire(_ view: PanelDropView) {
        let model = model
        view.onTargeted = { targeted = $0 }
        view.onFileURLs = { model.handleFiles($0) }
        view.onImage = { model.handleImage($0, suggestedName: "dropped-image.jpg") }
        view.onError = { model.attachNotice = $0 }
    }
}
