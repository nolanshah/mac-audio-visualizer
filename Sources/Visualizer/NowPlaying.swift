import AppKit

/// Polls Spotify over AppleScript for the current track and derives a palette from its artwork.
final class NowPlaying {
    struct Track: Equatable {
        var title: String
        var artist: String
        var artworkURL: String
    }

    var onTrackChange: ((Track) -> Void)?
    var onPalette: ((Palette) -> Void)?

    private var timer: Timer?
    private var current: Track?
    private var busy = false

    private static let script = """
    tell application "Spotify"
        if player state is stopped then return ""
        set t to current track
        return (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t)
    end tell
    """

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        // Never talk to Spotify unless it's already running, or AppleScript would launch it.
        guard !busy, !NSRunningApplication.runningApplications(withBundleIdentifier: AudioCapture.spotifyBundleID).isEmpty else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let output = Self.runOsascript(Self.script)
            DispatchQueue.main.async {
                self.busy = false
                let lines = output.components(separatedBy: "\n")
                guard lines.count >= 3, !lines[0].isEmpty else { return }
                let track = Track(title: lines[0], artist: lines[1], artworkURL: lines[2])
                guard track != self.current else { return }
                let artworkChanged = track.artworkURL != self.current?.artworkURL
                self.current = track
                self.onTrackChange?(track)
                if artworkChanged { self.loadArtwork(track.artworkURL) }
            }
        }
    }

    private func loadArtwork(_ urlString: String) {
        guard let url = URL(string: urlString), url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data), let palette = Palette.fromArtwork(image) else { return }
            DispatchQueue.main.async { self.onPalette?(palette) }
        }.resume()
    }

    private static func runOsascript(_ source: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
