import AppKit
import MetalKit

/// MTKView that forwards key presses and hides the cursor while idle.
final class VisualizerView: MTKView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// Small fading text overlay for track info and status messages.
final class HUD {
    let view = NSView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        view.wantsLayer = true
        view.alphaValue = 0
        title.font = .systemFont(ofSize: 26, weight: .light)
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        for label in [title, subtitle] {
            label.textColor = NSColor.white
            label.shadow = {
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.7)
                s.shadowBlurRadius = 8
                return s
            }()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        subtitle.textColor = NSColor.white.withAlphaComponent(0.7)
        NSLayoutConstraint.activate([
            subtitle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subtitle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            title.bottomAnchor.constraint(equalTo: subtitle.topAnchor, constant: -2),
            title.topAnchor.constraint(equalTo: view.topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])
    }

    func show(_ text: String, _ detail: String = "", for seconds: Double = 4) {
        title.stringValue = text
        subtitle.stringValue = detail
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.6; view.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 1.5; self?.view.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private let analyzer = AudioAnalyzer()
    private lazy var capture = AudioCapture(analyzer: analyzer)
    private let nowPlaying = NowPlaying()
    private let hud = HUD()
    private var source: AudioCapture.Source = .system
    private var paletteIndex = -1  // -1 = follow album art
    private var albumPalette: Palette?
    private var track: NowPlaying.Track?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available") }

        let view = VisualizerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        do {
            renderer = try Renderer(device: device, outputFormat: view.colorPixelFormat)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
        renderer.featuresProvider = { [analyzer] in analyzer.features }
        view.delegate = renderer
        view.onKey = { [weak self] in self?.handleKey($0) }

        window = NSWindow(contentRect: view.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Visualizer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        hud.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud.view)
        NSLayoutConstraint.activate([
            hud.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            hud.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -32),
            hud.view.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -36),
        ])

        nowPlaying.onTrackChange = { [weak self] t in
            self?.track = t
            self?.hud.show(t.title, t.artist, for: 6)
        }
        nowPlaying.onPalette = { [weak self] p in
            guard let self else { return }
            albumPalette = p
            if paletteIndex == -1 { renderer.targetPalette = p.colors }
        }
        nowPlaying.start()

        NSApp.activate(ignoringOtherApps: true)
        hud.show("Visualizer", "F fullscreen · M or 1–0 mode · P palette · S source", for: 6)
        startCapture(.system, announce: false)

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func startCapture(_ requested: AudioCapture.Source, announce: Bool = true, reconnecting: Bool = false) {
        // The stream dies when displays sleep or reconfigure (e.g. entering fullscreen); reconnect quietly.
        capture.onError = { [weak self] message in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self else { return }
                NSLog("Visualizer: reconnecting after: \(message)")
                self.startCapture(self.source, announce: false, reconnecting: true)
            }
        }
        Task { @MainActor in
            do {
                let actual = try await capture.start(source: requested)
                source = actual
                NSLog("Visualizer: capture started (\(actual.rawValue))")
                if requested == .spotify && actual != .spotify {
                    hud.show("Spotify isn't running", "Listening to system audio instead")
                } else if announce {
                    hud.show("Listening to \(actual.rawValue.lowercased())", "", for: 3)
                }
            } catch {
                NSLog("Visualizer: capture failed: \(error)")
                if reconnecting {
                    // Display may still be asleep; keep trying quietly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.startCapture(requested, announce: false, reconnecting: true)
                    }
                    return
                }
                hud.show("Can't capture audio",
                         "Allow Visualizer in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch.",
                         for: 30)
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, event.keyCode) {
        case ("f", _), (_, 36):
            window.toggleFullScreen(nil)
        case (_, 53):
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case ("m", _), (_, 124), (" ", _):
            switchMode(by: 1)
        case (_, 123):
            switchMode(by: -1)
        case ("p", _):
            cyclePalette()
        case ("s", _):
            startCapture(source == .system ? .spotify : .system)
        case ("0", _):
            switchMode(to: 9)
        case ("[", _), ("]", _):
            analyzer.beatLead += key == "]" ? 0.01 : -0.01
            hud.show(String(format: "Beat offset %+.0f ms", analyzer.beatLead * 1000),
                     "] = visuals earlier · [ = later", for: 2)
        case ("b", _):
            let f = analyzer.features
            hud.show(f.locked ? String(format: "%.0f BPM", f.bpm) : "Finding the beat…", "", for: 2)
        case ("t", _):
            if let track { hud.show(track.title, track.artist) }
        case let (k, _) where Int(k).map({ (1...Renderer.modeNames.count).contains($0) }) == true:
            switchMode(to: Int(k)! - 1)
        default:
            break
        }
    }

    private func switchMode(by delta: Int) { switchMode(to: renderer.mode + delta) }

    private func switchMode(to m: Int) {
        renderer.setMode(m)
        hud.show(Renderer.modeNames[renderer.mode], "", for: 2)
    }

    private func cyclePalette() {
        paletteIndex += 1
        if paletteIndex >= Palette.presets.count { paletteIndex = -1 }
        if paletteIndex == -1 {
            if let albumPalette {
                renderer.targetPalette = albumPalette.colors
                hud.show("Palette: album art", "", for: 2)
                return
            }
            paletteIndex = 0
        }
        let p = Palette.presets[paletteIndex]
        renderer.targetPalette = p.colors
        hud.show("Palette: \(p.name)", "", for: 2)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Visualizer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Visualizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--bench"), i + 2 < args.count, let w = Int(args[i + 1]), let h = Int(args[i + 2]) {
    Bench.run(width: w, height: h)
    exit(0)
}
if args.contains("--selftest") {
    SelfTest.run()
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Render each mode with synthetic audio to PNGs: Visualizer --snapshot <dir>
    Snapshot.run(outputDirectory: args[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
