import AVFoundation
import CoreImage
import ImageIO
import MultipeerConnectivity
import UIKit
import UniformTypeIdentifiers

/// JPEG is the only codec-specific part of the sender; transport carries opaque Packet payloads.
final class VideoEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var gate = FrameGate()
    private var destination: (MCSession, MCPeerID)?
    private var generation = UUID()
    var onError: ((String) -> Void)?

    func connect(session: MCSession?, peer: MCPeerID? = nil) {
        lock.lock()
        destination = peer.flatMap { peer in session.map { ($0, peer) } }
        gate = FrameGate()
        generation = UUID()
        lock.unlock()
    }

    func acknowledge(_ sequence: UInt32) {
        lock.lock()
        gate.acknowledge(sequence, now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    func checkForStall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.isStalled(now: ProcessInfo.processInfo.systemUptime)
    }

    /// Called synchronously on the capture output queue; no retained sample-buffer backlog.
    func encode(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard let destination,
              let sequence = gate.reserve(now: ProcessInfo.processInfo.systemUptime) else {
            lock.unlock()
            return
        }
        let token = generation
        let quality = gate.roundTrip > 0.12 ? 0.38 : 0.58
        lock.unlock()

        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            let longEdge = max(image.extent.width, image.extent.height)
            let shortEdge = min(image.extent.width, image.extent.height)
            let scale = min(1, min(1280 / longEdge, 720 / shortEdge))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let jpeg = context.jpegRepresentation(of: scaled, colorSpace: colorSpace,
                                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
                  jpeg.count <= Packet.maximumPayload else {
                fail("Could not encode the preview frame. Disconnect and try again.", token: token)
                return
            }
            lock.lock()
            let current = generation == token
            lock.unlock()
            guard current else { return }
            do {
                // Single in-flight reliable message: no unbounded MCSession send queue or fragment loss.
                try destination.0.send(Packet(kind: .jpeg, sequence: sequence, payload: jpeg).encoded(),
                                       toPeers: [destination.1], with: .reliable)
            } catch {
                fail("Preview send failed: \(error.localizedDescription)", token: token)
            }
        }
    }

    private func fail(_ message: String, token: UUID) {
        lock.lock()
        let current = generation == token
        if current { destination = nil }
        lock.unlock()
        if current { onError?(message) }
    }
}

final class VideoDecoder {
    private let queue = DispatchQueue(label: "com.lczerniawski.framelink.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false

    /// The completion runs on main; release occurs only after the display model consumes the frame.
    func decode(_ payload: Data, completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async {
            let image: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                      CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 1280, height <= 1280 else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            DispatchQueue.main.async {
                completion(image)
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
        }
    }
}
