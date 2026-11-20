import AppKit
import SwiftUI
import GPUWatchCore
import GPUWatchUI

// Visual QA harness.
//
// Two modes:
//
//   GPUWatchSnapshot <dir>                 render every screen as a still
//   GPUWatchSnapshot --video-frames <dir>  render the demo-video frame sequence
//
// Everything comes from the **real** view types driven by the real evaluator
// over the demo fleet, so what comes out is what the app shows. Demo mode opens
// no connections and raises no notifications, and the harness writes nothing to
// the operator's configuration.
//
// Frames are drawn by the view hierarchy itself rather than captured with
// `CGWindowListCreateImage`, which is deprecated, needs the screen-recording
// permission, and returned blank surfaces intermittently. Drawing the views also
// means nothing else on the operator's screen can end up in the output.

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
    } catch {
        FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
    }
}

/// True when an image carries no variation, i.e. it was drawn before anything
/// had laid out. A blank frame is worse than a missing one, because it looks
/// like a successful render.
func isBlank(_ image: CGImage) -> Bool {
    let side = 24
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &pixels, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let first = Array(pixels.prefix(4))
    for index in stride(from: 0, to: pixels.count, by: 4)
    where Array(pixels[index..<(index + 4)]) != first {
        return false
    }
    return true
}

// MARK: - Frame renderer

/// Owns one offscreen window and re-points its SwiftUI content per frame.
///
/// Reusing the window matters: creating one per frame cost roughly half a second
/// each, which over a forty-second sequence is minutes rather than seconds.
@MainActor
final class FrameRenderer {
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow

    init(size: CGSize) {
        controller = NSHostingController(rootView: AnyView(Color.clear))
        // No automatic sizing: the window has a deliberate size, and letting
        // SwiftUI derive one from the scrollable content would make it as tall
        // as the whole page.
        controller.sizingOptions = []
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Parked on screen rather than off it: a window that is entirely
        // offscreen is not guaranteed to be composited.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size.width - 16,
                y: screen.visibleFrame.minY + 16
            ))
        }
        window.orderFrontRegardless()
    }

    /// Draws at a pinned 2x scale. Taking the scale from the view's backing
    /// factor made consecutive runs produce differently sized files.
    private func capture() -> CGImage? {
        let view = controller.view
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Replaces the content, settles the layout, scrolls, and captures.
    func frame<Content: View>(_ content: Content, scrollFraction: Double?) -> CGImage? {
        controller.rootView = AnyView(content)
        // Two passes: one for the new content to lay out, one for the scroll to
        // take effect and the frame to be drawn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        if let scrollFraction {
            scroll(to: scrollFraction)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))

        var image: CGImage?
        for _ in 0..<6 {
            if let candidate = capture(), !isBlank(candidate) {
                image = candidate
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }
        return image
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews {
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }

    private func scroll(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        for scrollView in scrollViews(in: controller.view) {
            guard let document = scrollView.documentView else { continue }
            let limit = max(0, document.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: limit * clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
    }
}

// MARK: - Still mode

@MainActor
func renderStills(to directory: URL) {
    print("Rendering stills to \(directory.path)")
    let renderer = FrameRenderer(size: CGSize(width: 400, height: 700))
    defer { renderer.close() }

    for scenario in SnapshotScenarios.scenarios() {
        let fraction: Double? = scenario.scrollToBottom ? 1 : nil
        guard let image = renderer.frame(scenario.view, scrollFraction: fraction) else {
            FileHandle.standardError.write(Data("no image for \(scenario.name)\n".utf8))
            continue
        }
        write(image, to: directory.appendingPathComponent("\(scenario.name).png"))
        print("  \(scenario.name).png  \(image.width)x\(image.height)")
    }
}

// MARK: - Video mode

@MainActor
func renderVideoFrames(to directory: URL) {
    let fps = DemoVideoShots.framesPerSecond
    let shots = DemoVideoShots.shots

    print("Rendering demo-video frames to \(directory.path)")
    print("  \(shots.count) shots, \(Int(DemoVideoShots.totalSeconds))s total at \(Int(fps)) fps")

    let coordinator = SnapshotScenarios.makeDemoCoordinator()
    defer { coordinator.stop() }

    let renderer = FrameRenderer(size: SnapshotScenarios.popoverSize)
    defer { renderer.close() }

    var frameIndex = 0
    var manifest: [String] = []

    for shot in shots {
        let frameCount = max(1, Int((shot.durationSeconds * fps).rounded()))
        for step in 0..<frameCount {
            let progress = frameCount == 1 ? 1 : Double(step) / Double(frameCount - 1)
            let eased = DemoVideoShots.ease(progress)
            let fraction = shot.scrollFrom + (shot.scrollTo - shot.scrollFrom) * eased

            DemoVideoShots.apply(shot, to: coordinator)
            let view = SnapshotScenarios.popoverView(coordinator: coordinator)

            guard let image = renderer.frame(view, scrollFraction: fraction) else {
                FileHandle.standardError.write(
                    Data("no image for \(shot.name) frame \(step)\n".utf8)
                )
                continue
            }
            let name = String(format: "frame-%05d.png", frameIndex)
            write(image, to: directory.appendingPathComponent(name))
            manifest.append("\(name)\t\(shot.name)\t\(shot.caption ?? "")")
            frameIndex += 1
        }
        print("  \(shot.name): \(frameCount) frames")
    }

    // The caption manifest lets the assembly step burn in the right text for the
    // right span of frames without duplicating the storyboard.
    let manifestURL = directory.appendingPathComponent("captions.tsv")
    try? manifest.joined(separator: "\n").write(to: manifestURL, atomically: true, encoding: .utf8)

    print("  total frames: \(frameIndex)")
    print("  manifest: \(manifestURL.path)")
}

// MARK: - Entry

@MainActor
func run() {
    let arguments = CommandLine.arguments
    let videoMode = arguments.contains("--video-frames")

    var outputPath: String?
    if let index = arguments.firstIndex(of: "--video-frames"), index + 1 < arguments.count {
        outputPath = arguments[index + 1]
    } else if arguments.count > 1, !arguments[1].hasPrefix("--") {
        outputPath = arguments[1]
    }
    let directory = URL(
        fileURLWithPath: outputPath ?? (FileManager.default.currentDirectoryPath + "/dist/screenshots"),
        isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.appearance = NSAppearance(named: .darkAqua)

    if videoMode {
        renderVideoFrames(to: directory)
    } else {
        renderStills(to: directory)
        print("The menu bar label itself is an NSStatusItem outside SwiftUI; verify it")
        print("with:  GPUWatch.app/Contents/MacOS/GPUWatch --show-popover")
    }

    print("Done.")
    exit(0)
}

// Top-level code in `main.swift` already runs on the main thread, so the
// main-actor rendering entry point can be called directly.
MainActor.assumeIsolated {
    run()
}
