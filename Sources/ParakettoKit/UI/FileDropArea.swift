import AppKit
import SwiftUI

/// Takes dropped files through AppKit. AppKit removes the drag image when it is released, before the
/// drop is handled; SwiftUI's `dropDestination` left Finder's image on screen for a moment after the drop.
/// The content is hosted inside this view because AppKit only offers a drop to the view under the
/// pointer and its ancestors.
struct FileDropArea: NSViewRepresentable {
    let isTargeted: (Bool) -> Void
    let drop: ([URL]) -> Bool
    let content: AnyView

    func makeNSView(context: Context) -> FileDropView {
        FileDropView(content: content)
    }

    func updateNSView(_ view: FileDropView, context: Context) {
        view.hosting.rootView = content
        view.isTargeted = isTargeted
        view.drop = drop
    }
}

final class FileDropView: NSView {
    let hosting: NSHostingView<AnyView>
    var isTargeted: (Bool) -> Void = { _ in }
    var drop: ([URL]) -> Bool = { _ in false }

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        // The window's size comes from the SwiftUI around this view, not from the content inside it.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    private func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(in: sender).isEmpty else { return [] }
        isTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted(false)
        return drop(fileURLs(in: sender))
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isTargeted(false)
    }
}
