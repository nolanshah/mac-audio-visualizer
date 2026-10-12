import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures system (or Spotify-only) audio through ScreenCaptureKit and feeds mono PCM to the analyzer.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Source: String { case system = "System audio", spotify = "Spotify" }

    static let spotifyBundleID = "com.spotify.client"

    private let analyzer: AudioAnalyzer
    private let queue = DispatchQueue(label: "visualizer.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var left: [Float] = []
    private var right: [Float] = []
    private var loggedFormat = false
    private var lastHeartbeat = Date.distantPast
    var onError: ((String) -> Void)?

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    /// Starts capture and returns the source actually in use (falls back to system audio).
    func start(source requested: Source) async throws -> Source {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Visualizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        var source = requested
        let filter: SCContentFilter
        if requested == .spotify,
           let spotify = content.applications.first(where: { $0.bundleIdentifier == AudioCapture.spotifyBundleID }) {
            filter = SCContentFilter(display: display, including: [spotify], exceptingWindows: [])
        } else {
            source = .system
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Video is mandatory but unused: keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return source
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        let frames = sampleBuffer.numSamples
        guard frames > 0 else { return }
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(asbd.mChannelsPerFrame)
        if !loggedFormat {
            loggedFormat = true
            NSLog("Visualizer: first audio buffer \(asbd.mSampleRate) Hz, \(channels) ch, interleaved=\(interleaved)")
        }
        if Date().timeIntervalSince(lastHeartbeat) > 2 {
            lastHeartbeat = Date()
            let f = analyzer.features
            NSLog("Visualizer: level=%.2f bass=%.2f beats=%d bpm=%.0f %@", f.level, f.bass, f.beatCount, f.bpm, analyzer.trackerDebug as NSString)
        }

        try? sampleBuffer.withAudioBufferList { list, _ in
            if left.count != frames {
                left = [Float](repeating: 0, count: frames)
                right = [Float](repeating: 0, count: frames)
            }
            if interleaved {
                guard let data = list.first?.mData else { return }
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    left[i] = p[i * channels]
                    right[i] = p[i * channels + min(1, channels - 1)]
                }
            } else {
                guard let l = list.first?.mData else { return }
                let r = list.count > 1 ? list[1].mData ?? l : l
                let lp = l.assumingMemoryBound(to: Float.self), rp = r.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { left[i] = lp[i]; right[i] = rp[i] }
            }
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    analyzer.process(left: l, right: r, sampleRate: Float(asbd.mSampleRate))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Visualizer: stream stopped: \(error)")
        onError?(error.localizedDescription)
    }
}
