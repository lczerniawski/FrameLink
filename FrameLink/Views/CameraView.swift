import AVFoundation
import SwiftUI

struct CameraView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var peers: PeerConnectionManager
    @ObservedObject var recentPhotos: RecentPhotoStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var level = CameraLevel()
    @State private var showDevices = false
    @State private var showRecentPhotos = false
    @State private var showControls = false
    @State private var photoTimer: PhotoTimer = .off
    @State private var showGrid = false
    @State private var showLevel = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = verticalSizeClass == .compact
            Group {
                if landscape {
                    if geometry.size.height < 196 {
                        ScrollView { landscapeCamera.frame(height: 196) }
                            .accessibilityIdentifier("Compact camera layout")
                    } else {
                        landscapeCamera
                    }
                } else {
                    VStack(spacing: 0) { cameraSurface; controls(landscape: false).frame(minHeight: 138) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ConnectionStatusView(peers: peers, cameraReady: camera.isReady)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                CameraQuickControls(flash: Binding(get: { camera.flashMode }, set: { camera.setFlash($0) }),
                                    flashModes: camera.flashModes, timer: $photoTimer)
                    .disabled(!camera.isReady || camera.isCapturing)
            }
            .background(Color.black)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showControls = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .accessibilityLabel("Camera settings")
                .accessibilityHint("Exposure, grid, and level")
            }
            ToolbarItem(placement: .topBarTrailing) { devicesButton }
        }
        .sheet(isPresented: $showDevices) { NearbyDevicesView(peers: peers) }
        .sheet(isPresented: $showControls) {
            CameraSettingsView(camera: camera, showGrid: $showGrid, showLevel: $showLevel, levelAvailable: level.isAvailable)
        }
        .fullScreenCover(isPresented: $showRecentPhotos) { RecentPhotosView(store: recentPhotos) }
        .onReceive(recentPhotos.$errorMessage) { message in
            if let message, !showRecentPhotos { camera.errorMessage = message }
        }
        .onChange(of: showLevel && scenePhase == .active && !showRecentPhotos, initial: true) { _, active in
            if active { level.start() } else { level.stop() }
        }
        .onDisappear { level.stop(); camera.cancelTimer() }
    }

    private var cameraSurface: some View {
        ZStack {
            Color.black
            if !camera.cameraDenied {
                CameraPreview(camera: camera).accessibilityHidden(!camera.isReady)
            }
            if camera.isReady {
                if showGrid {
                    GeometryReader { geometry in
                        Path { path in
                            for fraction in [1.0 / 3, 2.0 / 3] {
                                let x = geometry.size.width * fraction
                                let y = geometry.size.height * fraction
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(.white.opacity(0.65), lineWidth: 0.5)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                if showLevel, let angle = level.angle { CameraHorizonGuide(angle: angle) }
                if abs(camera.exposureBias) > 0.05 {
                    VStack {
                        HStack {
                            Text("EV \(camera.exposureBias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))")
                                .font(.caption.weight(.semibold))
                                .padding(8).background(.black.opacity(0.6), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8).allowsHitTesting(false)
                }
                if let second = camera.countdown {
                    Text("\(second)")
                        .font(.system(size: 80, weight: .medium, design: .rounded))
                        .padding(24).background(.black.opacity(0.65), in: Circle())
                        .allowsHitTesting(false)
                        .accessibilityLabel("Photo in \(second) seconds")
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: camera.cameraDenied ? "camera.fill.badge.xmark" : "camera")
                            .font(.largeTitle)
                        Text(camera.status).multilineTextAlignment(.center)
                        if camera.cameraDenied {
                            Button("Allow Camera in Settings", action: openSettings).buttonStyle(.borderedProminent)
                        } else {
                            Button("Retry camera", action: camera.start).buttonStyle(.bordered)
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .accessibilityIdentifier("Camera status")
                .background(.black.opacity(0.8))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if camera.isReady {
                CameraZoomControls(zoom: Binding(get: { camera.zoomFactor }, set: { camera.setZoom($0) }),
                                   zoomStops: camera.zoomStops)
                    .padding(12).disabled(camera.isCapturing)
            }
        }
        .clipped()
    }

    private var landscapeCamera: some View {
        HStack(spacing: 0) { cameraSurface; controls(landscape: true).frame(width: 150) }
    }

    private func controls(landscape: Bool) -> some View {
        Group {
            if landscape {
                VStack(spacing: 4) { recentPhotosButton; shutter; switchButton }
            } else {
                HStack(spacing: 30) { recentPhotosButton; shutter; switchButton }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, landscape ? 0 : 20)
        .padding(.bottom, landscape ? 16 : 20)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if camera.status == "Saved to Photos" {
                Text("Saved to Photos").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    .accessibilityLabel("Photo saved to this iPhone's Photos library")
            }
        }
    }

    private var recentPhotosButton: some View {
        Button { showRecentPhotos = true } label: {
            ZStack {
                if let image = recentPhotos.thumbnail {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 22))
                }
                if recentPhotos.isLoading { ProgressView() }
            }
            .frame(width: 48, height: 48)
        }
        .disabled(recentPhotos.isLoading || camera.isCapturing)
        .accessibilityLabel("Recent photos")
        .accessibilityHint(recentPhotos.photos.isEmpty ? "No photos taken on this iPhone yet" : "Opens the last \(recentPhotos.photos.count) photos taken on this iPhone")
    }

    private var devicesButton: some View {
        Button { showDevices = true } label: {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 22)).frame(width: 48, height: 48)
        }
        .accessibilityLabel("Nearby preview devices")
    }

    private var switchButton: some View {
        Button(action: camera.switchCamera) {
            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 22)).frame(width: 48, height: 48)
        }
        .disabled(!camera.isReady || camera.isCapturing)
        .accessibilityLabel("Switch front and rear cameras")
    }

    private var shutter: some View {
        Button {
            if camera.countdown != nil { camera.cancelTimer() }
            else { camera.capturePhoto(timer: photoTimer) }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 76, height: 76)
                Circle().fill(camera.countdown == nil ? .white : .yellow).frame(width: 64, height: 64)
                if camera.countdown != nil {
                    Image(systemName: "xmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black)
                } else if camera.isCapturing { ProgressView().tint(.black) }
            }
            .opacity(camera.isReady ? 1 : 0.4)
        }
        .disabled(!camera.isReady || (camera.isCapturing && camera.countdown == nil))
        .accessibilityLabel(camera.countdown != nil ? "Cancel timer" : (camera.isCapturing ? "Saving photo" : "Take photo"))
        .accessibilityHint("Saves a full-resolution photo on this iPhone only")
    }
}

private struct CameraSettingsView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    let levelAvailable: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if camera.exposureRange.lowerBound < camera.exposureRange.upperBound {
                        LabeledContent("Exposure", value: "\(camera.exposureBias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) EV")
                        Slider(value: Binding(get: { camera.exposureBias }, set: camera.setExposure), in: camera.exposureRange)
                            .accessibilityLabel("Exposure compensation")
                            .accessibilityValue("\(camera.exposureBias.formatted(.number.precision(.fractionLength(1)))) EV")
                        Button("Reset exposure") { camera.setExposure(0) }
                    }
                } header: { Text("Exposure") } footer: {
                    Text(camera.supportsMetering ? "Tap the scene to focus and meter exposure. Pinch to zoom, or use the zoom buttons at the bottom-left of the preview. Flash and timer are above the preview." : "Tap-to-focus and metering are unavailable on this camera. Pinch to zoom, or use the bottom-left zoom buttons. Flash and timer are above the preview.")
                }
                Section("Composition") {
                    Toggle("Grid", isOn: $showGrid)
                    Toggle("Level", isOn: $showLevel)
                    if !levelAvailable { Text("Motion data is unavailable, so the level guide is hidden.").foregroundStyle(.secondary) }
                    Text("The thin horizon guide turns yellow when level and hides when the phone is nearly flat. Overlays are not included in saved photos or the remote preview.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!camera.isReady || camera.isCapturing)
            .navigationTitle("Camera settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraManager

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.connect(camera: camera)
        return view
    }

    func updateUIView(_ view: PreviewSurface, context: Context) { view.configure(camera: camera) }

    static func dismantleUIView(_ view: PreviewSurface, coordinator: ()) { view.disconnect() }

    final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private weak var camera: CameraManager?
        private var sessionConnected = false
        private var deviceID: String?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var previewObservation: NSKeyValueObservation?
        private var captureObservation: NSKeyValueObservation?
        private var pinchStartZoom: Double = 1
        private let focusBox = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
            focusBox.borderColor = UIColor.systemYellow.cgColor
            focusBox.borderWidth = 1.5
            focusBox.bounds = CGRect(x: 0, y: 0, width: 70, height: 70)
            focusBox.opacity = 0
            focusBox.actions = ["position": NSNull(), "opacity": NSNull()]
            layer.addSublayer(focusBox)
            isAccessibilityElement = true
            accessibilityLabel = "Local camera preview"
            accessibilityHint = "Double-tap to focus at the center. Swipe up or down to adjust zoom."
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func accessibilityActivate() -> Bool {
            guard sessionConnected, let camera, camera.isReady, !camera.isCapturing, camera.supportsMetering else { return false }
            focus(at: CGPoint(x: bounds.midX, y: bounds.midY))
            return true
        }

        override func accessibilityIncrement() {
            guard let camera else { return }
            camera.setZoom(camera.zoomFactor * 1.1)
        }

        override func accessibilityDecrement() {
            guard let camera else { return }
            camera.setZoom(camera.zoomFactor / 1.1)
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) { focus(at: gesture.location(in: self)) }

        private func focus(at point: CGPoint) {
            guard sessionConnected, let camera, camera.isReady, !camera.isCapturing, camera.supportsMetering else { return }
            camera.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            focusBox.removeAllAnimations()
            focusBox.position = point
            focusBox.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + 1.5
            fade.duration = 0.2
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            focusBox.add(fade, forKey: "focus")
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let camera else { return }
            if gesture.state == .began { pinchStartZoom = camera.zoomFactor }
            if gesture.state == .began || gesture.state == .changed {
                camera.setZoom(pinchStartZoom * Double(gesture.scale))
            }
        }

        func connect(camera: CameraManager) {
            self.camera = camera
            camera.attachPreview(previewLayer) { [weak self] in
                guard let self, let camera = self.camera else { return }
                self.sessionConnected = true
                self.configure(camera: camera)
            }
        }

        func disconnect() {
            sessionConnected = false
            previewObservation = nil
            captureObservation = nil
            rotationCoordinator = nil
            deviceID = nil
            camera?.detachPreview(previewLayer)
            camera = nil
        }

        func configure(camera: CameraManager) {
            self.camera = camera
            accessibilityTraits = camera.supportsMetering ? .button : .image
            let canZoom = camera.zoomRange.lowerBound < camera.zoomRange.upperBound
            if canZoom { accessibilityTraits.insert(.adjustable) }
            accessibilityValue = "Zoom \(camera.zoomFactor.formatted(.number.precision(.fractionLength(1)))) times"
            accessibilityHint = (camera.supportsMetering ? "Double-tap to focus at the center. " : "")
                + (canZoom ? "Swipe up or down to adjust zoom. " : "")
                + "Exposure is available in Camera settings."
            guard sessionConnected, let device = camera.device, deviceID != device.uniqueID else { return }
            deviceID = device.uniqueID
            focusBox.removeAllAnimations()
            focusBox.opacity = 0
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                guard let self, let camera = self.camera else { return }
                camera.setPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview,
                                          mirrored: device.position == .front, for: self.previewLayer)
            }
            captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak camera] coordinator, _ in
                camera?.setRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
        }
    }
}
