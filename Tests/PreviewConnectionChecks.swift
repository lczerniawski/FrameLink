import AVFoundation
import Foundation

@main
struct PreviewConnectionChecks {
    @MainActor static func main() async {
        let camera = CameraManager()
        let visible = AVCaptureVideoPreviewLayer()
        let overlapping = AVCaptureVideoPreviewLayer()
        await attach(visible, to: camera)
        guard let session = visible.session else { fatalError("The native preview must retain its session") }

        await attach(overlapping, to: camera)
        precondition(visible.session === session, "An overlapping preview must not disconnect the visible preview")
        precondition(overlapping.session === session)

        camera.detachPreview(visible)
        await camera.previewQueueBarrier()
        precondition(visible.session == nil)
        precondition(overlapping.session === session, "Old-view teardown must not disconnect another preview")

        await attach(visible, to: camera)
        precondition(overlapping.session === session)
        camera.detachPreview(overlapping)
        await camera.previewQueueBarrier()
        precondition(visible.session === session)
        precondition(overlapping.session == nil)

        camera.detachPreview(overlapping)
        await camera.previewQueueBarrier()
        precondition(visible.session === session, "Repeated stale teardown must be harmless")
        camera.detachPreview(visible)
        await camera.previewQueueBarrier()
        precondition(visible.session == nil)
        print("Frame Link native preview connection ownership checks passed")
    }

    @MainActor private static func attach(_ layer: AVCaptureVideoPreviewLayer, to camera: CameraManager) async {
        await withCheckedContinuation { continuation in
            camera.attachPreview(layer) { continuation.resume() }
        }
    }
}
