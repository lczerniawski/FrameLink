import Combine
import CoreMotion
import Foundation

@MainActor
final class CameraLevel: ObservableObject {
    @Published private(set) var angle: Double?
    @Published private(set) var isAvailable = true
    private let motion = CMMotionManager()
    private var updateID: UUID?

    func start() {
        guard !motion.isDeviceMotionActive else { return }
        guard motion.isDeviceMotionAvailable else { isAvailable = false; return }
        isAvailable = true
        let id = UUID()
        updateID = id
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            let angle = sample.flatMap { CameraControlMath.levelAngle(x: $0.gravity.x, y: $0.gravity.y) }
            Task { @MainActor [weak self] in
                guard let self, self.updateID == id else { return }
                self.isAvailable = error == nil
                self.angle = angle
            }
        }
    }

    func stop() {
        updateID = nil
        motion.stopDeviceMotionUpdates()
        angle = nil
    }
}
