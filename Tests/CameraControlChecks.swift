import Foundation

@main
struct CameraControlChecks {
    static func main() {
        precondition(PhotoTimer.off.ticks.isEmpty)
        precondition(PhotoTimer.three.ticks == [3, 2, 1])
        precondition(PhotoTimer.ten.ticks == Array((1...10).reversed()))
        precondition(CameraFlash.allCases.map(\.rawValue) == ["off", "auto", "on"])
        precondition(PhotoTimer.off.next == .three && PhotoTimer.three.next == .ten && PhotoTimer.ten.next == .off)
        precondition(CameraFlash.off.next(in: [.off, .auto, .on]) == .auto)
        precondition(CameraFlash.auto.next(in: [.off, .auto, .on]) == .on)
        precondition(CameraFlash.on.next(in: [.off, .auto, .on]) == .off)
        precondition(CameraFlash.off.next(in: [.off, .on]) == .on, "Skip unsupported flash settings")
        precondition(CameraFlash.off.next(in: [.off]) == .off)
        precondition(CameraFlash.auto.next(in: [.off, .on]) == .off)
        precondition(CameraFlash.off.next(in: []) == .off)

        precondition(CameraControlMath.clamp(0.1, to: 0.5...8) == 0.5)
        precondition(CameraControlMath.clamp(99, to: 0.5...8) == 8)
        precondition(CameraControlMath.clamp(2.5, to: 0.5...8) == 2.5)
        precondition(CameraControlMath.clamp(-4, to: -2...2) == -2)
        precondition(CameraControlMath.clamp(.nan, to: 1...1) == 1)
        precondition(CameraControlMath.clamp(.infinity, to: 0...2) == 0)
        let triple = CameraControlMath.zoomStops(range: 0.5...15, multiplier: 0.5, nativeFactors: [2, 4, 6, 6])
        precondition(triple == [0.5, 1, 2, 3], "Use the system multiplier, lens switches, and native sensor-crop factors")
        let single = CameraControlMath.zoomStops(range: 1...5, multiplier: 1, nativeFactors: [])
        precondition(single == [1], "Do not invent an ultrawide or telephoto lens")
        let restricted = CameraControlMath.zoomStops(range: 2...4, multiplier: 1, nativeFactors: [-1, 1, 3, 5, .nan, .infinity])
        precondition(restricted == [2, 3], "Only expose finite stops in the available range")
        precondition(CameraControlMath.zoomStops(range: 1...1, multiplier: 1, nativeFactors: [1]) == [1])

        for (x, y) in [(0.0, -1.0), (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0)] {
            precondition(abs(CameraControlMath.levelAngle(x: x, y: y)!) < 0.0001, "Level is orientation-independent")
        }
        let tilt = 10.0 * .pi / 180
        precondition(abs(CameraControlMath.levelAngle(x: sin(tilt), y: -cos(tilt))! + 10) < 0.0001)
        precondition(abs(CameraControlMath.levelAngle(x: -sin(tilt), y: -cos(tilt))! - 10) < 0.0001)
        precondition(CameraControlMath.levelAngle(x: 0, y: 0) == nil, "Do not report a false horizon when the phone is flat")
        precondition(CameraControlMath.levelAngle(x: 0.1, y: 0.1) == nil)
        precondition(CameraControlMath.levelAngle(x: .nan, y: -1) == nil)
        print("Frame Link camera-control checks passed")
    }
}
