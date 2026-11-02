import Foundation

enum CameraFlash: String, CaseIterable, Identifiable {
    case off, auto, on
    var id: Self { self }
    var title: String { rawValue.capitalized }
    func next(in supported: [Self]) -> Self {
        guard let index = supported.firstIndex(of: self) else { return supported.first ?? .off }
        return supported[(index + 1) % supported.count]
    }
    var symbol: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        }
    }
}

enum PhotoTimer: Int, CaseIterable, Identifiable {
    case off = 0, three = 3, ten = 10
    var id: Self { self }
    var title: String { self == .off ? "Off" : "\(rawValue) seconds" }
    var ticks: [Int] { Array(stride(from: rawValue, to: 0, by: -1)) }
    var next: Self {
        switch self {
        case .off: return .three
        case .three: return .ten
        case .ten: return .off
        }
    }
}

enum CameraControlMath {
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func zoomStops(range: ClosedRange<Double>, multiplier: Double, nativeFactors: [Double]) -> [Double] {
        let values = [range.lowerBound, 1] + nativeFactors.map { $0 * multiplier }
        return Array(Set(values.filter { $0.isFinite && range.contains($0) })).sorted()
    }

    /// Gravity projected into the screen plane; near-flat phones do not have a usable horizon.
    static func levelAngle(x: Double, y: Double) -> Double? {
        guard x.isFinite, y.isFinite, hypot(x, y) > 0.25 else { return nil }
        let angle = atan2(-x, -y) * 180 / .pi
        return angle - (angle / 90).rounded() * 90
    }
}
