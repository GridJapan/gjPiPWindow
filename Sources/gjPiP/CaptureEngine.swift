import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Wraps a single ScreenCaptureKit stream for one display and hands finished
/// frames to `onFrame` as IOSurfaces, which a CALayer can display zero-copy.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called on the main thread for every complete frame.
    var onFrame: ((IOSurfaceRef) -> Void)?
    /// Called on the main thread when the stream dies on its own.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "gjPiP.capture", qos: .userInteractive)

    private(set) var frameRate: Int = 60

    private var frameCount = 0

    func start(display: SCDisplay, frameRate: Int) async throws {
        stop()
        self.frameRate = frameRate

        let scale = Self.pixelScale(for: display.displayID)
        let config = SCStreamConfiguration()
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// Backing-store scale of a display, so we capture at native pixel density
    /// rather than the point size ScreenCaptureKit reports.
    private static func pixelScale(for displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Skip idle/blank frames — the stream repeats the last surface with a
        // non-.complete status when nothing on screen changed.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        if Debug.enabled {
            frameCount += 1
            if frameCount == 1 || frameCount % 120 == 0 {
                Debug.log("frame \(frameCount) — \(IOSurfaceGetWidth(surface))×\(IOSurfaceGetHeight(surface))")
            }
        }

        // `surface` is retained by ARC for the lifetime of the closure, so it
        // outlives the sample buffer.
        DispatchQueue.main.async { [onFrame] in onFrame?(surface) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [onStop] in onStop?(error) }
    }
}
