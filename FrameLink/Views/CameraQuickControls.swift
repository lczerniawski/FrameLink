import SwiftUI

struct CameraQuickControls: View {
    @Binding var flash: CameraFlash
    let flashModes: [CameraFlash]
    @Binding var timer: PhotoTimer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { flashButton; timerButton; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) { flashButton; timerButton }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(.black)
    }

    private var flashButton: some View {
        Button { flash = flash.next(in: flashModes) } label: {
            Label(flash.title, systemImage: flash.symbol)
                .font(.subheadline.weight(.semibold)).fixedSize()
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(flash == .off ? Color.white : .black)
                .background(flash == .off ? Color.white.opacity(0.12) : .yellow, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(flashModes.count < 2)
        .accessibilityLabel("Flash")
        .accessibilityValue(flashModes.count < 2 ? "Unavailable on this camera" : flash.title)
        .accessibilityHint("Cycles through supported flash settings")
    }

    private var timerButton: some View {
        Button { timer = timer.next } label: {
            Label(timer == .off ? "Off" : "\(timer.rawValue)s", systemImage: "timer")
                .font(.subheadline.weight(.semibold)).fixedSize()
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(timer == .off ? Color.white : .black)
                .background(timer == .off ? Color.white.opacity(0.12) : .yellow, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo timer")
        .accessibilityValue(timer.title)
        .accessibilityHint("Cycles through Off, 3 seconds, and 10 seconds")
    }

}

struct CameraZoomControls: View {
    @Binding var zoom: Double
    let zoomStops: [Double]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(zoomStops, id: \.self) { value in
                    let selected = abs(zoom - value) < 0.04
                    Button { zoom = value } label: {
                        Text("\(value.formatted(.number.precision(.fractionLength(0...1))))×")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(selected ? Color.black : .white)
                            .background(selected ? Color.yellow : .black.opacity(0.75), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom \(value.formatted()) times")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if !zoomStops.contains(where: { abs(zoom - $0) < 0.04 }) {
                    Text("\(zoom.formatted(.number.precision(.fractionLength(1))))×")
                        .font(.subheadline.monospacedDigit()).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.black.opacity(0.75), in: Capsule())
                        .accessibilityLabel("Current zoom")
                        .accessibilityValue("\(zoom.formatted()) times")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CameraHorizonGuide: View {
    let angle: Double

    var body: some View {
        HStack(spacing: 8) {
            Capsule().frame(width: 24, height: 2)
            Capsule().frame(width: 64, height: 2).rotationEffect(.degrees(angle))
            Capsule().frame(width: 24, height: 2)
        }
        .foregroundStyle(abs(angle) <= 1 ? Color.yellow : .white)
        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
        .frame(width: 144, height: 64)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(abs(angle) <= 1 ? "Camera level" : "Camera tilt \(abs(angle).formatted(.number.precision(.fractionLength(0)))) degrees")
    }
}
