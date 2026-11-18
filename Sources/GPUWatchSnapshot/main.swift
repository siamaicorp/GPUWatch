import AppKit
import SwiftUI
import GPUWatchUI

// Visual QA harness.
//
// Renders the real view types in real windows so the interface can be inspected
// without clicking through a menu bar item.
//
// It uses real windows rather than `ImageRenderer` on purpose: `ImageRenderer`
// does not lay out `ScrollView` content, which is most of what the popover is.
// A window also resolves the material backgrounds the app actually uses.
//
// It builds a coordinator over a throwaway store in demo mode, so it never
// touches the operator's configuration and never opens a network connection.
//
//   swift run GPUWatchSnapshot [output-directory]

// MARK: - Output

@MainActor
func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(url.lastPathComponent)\n".utf8))
        return
    }
    do {
        try data.write(to: url)
        print("  \(url.lastPathComponent)  \(image.width)x\(image.height)")
    } catch {
        FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
    }
}

// MARK: - Capture

/// Draws the view hierarchy into a bitmap at a fixed 2x scale.
///
/// Deliberately not `CGWindowListCreateImage`: that API is deprecated on this
/// deployment target, needs the screen-recording permission, and returned blank
/// surfaces intermittently under load. Drawing our own view needs neither.
///
/// The scale is pinned rather than taken from the view's backing factor, which
/// varies with whether the offscreen window happens to be considered key and
/// made consecutive runs produce differently sized files.
@MainActor
func captureView(_ view: NSView) -> CGImage? {
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width * scale),
        pixelsHigh: Int(view.bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
}

/// True when an image carries no variation, i.e. the capture happened before
/// anything was drawn.
///
/// The window server will happily return an empty surface if asked too early,
/// and a blank PNG is worse than no PNG because it looks like a successful run.
func isBlank(_ image: CGImage) -> Bool {
    let side = 24
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &pixels,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return false
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let first = Array(pixels.prefix(4))
    for index in stride(from: 0, to: pixels.count, by: 4) {
        if Array(pixels[index..<(index + 4)]) != first { return false }
    }
    return true
}

@MainActor
func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    if let scrollView = view as? NSScrollView { found.append(scrollView) }
    for subview in view.subviews {
        found.append(contentsOf: scrollViews(in: subview))
    }
    return found
}

/// Scrolls every scroll view in the hierarchy to its end. Used to inspect
/// content that sits below the fold in the popover.
@MainActor
func scrollToBottom(_ view: NSView) {
    for scrollView in scrollViews(in: view) {
        guard let document = scrollView.documentView else { continue }
        let limit = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: limit))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

@MainActor
func render(_ view: AnyView, size: CGSize, opaque: Bool, scrollToBottom shouldScroll: Bool = false) -> CGImage? {
    let content = ZStack {
        if opaque {
            // A real window supplies this in the app; the harness asks for it
            // explicitly so the capture is legible on any desktop.
            Color(nsColor: .windowBackgroundColor)
        }
        view
    }
    .frame(width: size.width, height: size.height)
    .environment(\.colorScheme, .dark)

    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.isOpaque = opaque
    window.backgroundColor = opaque ? .windowBackgroundColor : .clear
    window.hasShadow = false
    window.contentView = hosting
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    // Parked at the bottom-right of the screen rather than off it: a window that
    // is entirely offscreen is not guaranteed to be composited, and the capture
    // would come back empty.
    if let screen = NSScreen.main {
        window.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - size.width - 24,
            y: screen.visibleFrame.minY + 24
        ))
    }
    window.orderFrontRegardless()

    // Wait for the window to be composited, then for a few more frames. A fixed
    // sleep alone was not enough — the capture would intermittently come back
    // blank depending on machine load.
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, !window.occlusionState.contains(.visible) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))

    if shouldScroll {
        scrollToBottom(hosting)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    var image: CGImage?
    for _ in 0..<8 {
        if let candidate = captureView(hosting), !isBlank(candidate) {
            image = candidate
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    window.orderOut(nil)
    window.contentView = nil
    return image
}

// MARK: - Entry

@MainActor
func runSnapshots() {
    let arguments = CommandLine.arguments
    let outputDirectory = arguments.count > 1
        ? URL(fileURLWithPath: arguments[1], isDirectory: true)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/screenshots", isDirectory: true)

    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.appearance = NSAppearance(named: .darkAqua)

    print("Rendering to \(outputDirectory.path)")

    for scenario in SnapshotScenarios.scenarios() {
        if let image = render(
            scenario.view,
            size: scenario.size,
            opaque: scenario.opaqueBackground,
            scrollToBottom: scenario.scrollToBottom
        ) {
            write(image, to: outputDirectory.appendingPathComponent("\(scenario.name).png"))
        } else {
            FileHandle.standardError.write(
                Data("no image for \(scenario.name)\n".utf8)
            )
        }
    }


    print("Done.")
    print("The menu bar label itself is an NSStatusItem outside SwiftUI; verify it")
    print("with:  GPUWatch.app/Contents/MacOS/GPUWatch --show-popover")
    exit(0)
}

// Top-level code in `main.swift` already runs on the main thread, so the
// main-actor rendering entry point can be called directly.
MainActor.assumeIsolated {
    runSnapshots()
}
