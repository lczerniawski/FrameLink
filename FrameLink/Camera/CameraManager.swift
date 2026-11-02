import AVFoundation
import Combine
import Photos
import UIKit
import os

// Capture state is sessionQueue-confined; published UI state is changed only on main.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    let recentPhotos: RecentPhotoStore
    @Published private(set) var device: AVCaptureDevice?
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var status = "Starting camera…"
    @Published var errorMessage: String?
    @Published private(set) var zoomFactor: Double = 1
    @Published private(set) var zoomRange: ClosedRange<Double> = 1...1
    @Published private(set) var zoomStops: [Double] = [1]
    @Published private(set) var exposureBias: Double = 0
    @Published private(set) var exposureRange: ClosedRange<Double> = 0...0
    @Published private(set) var supportsMetering = false
    @Published private(set) var flashModes: [CameraFlash] = [.off]
    @Published private(set) var flashMode: CameraFlash = .off
    @MainActor @Published private(set) var countdown: Int?
    @MainActor private var countdownTask: Task<Void, Never>?
    @MainActor private var scheduledCaptureID: UUID?

    private let sessionQueue = DispatchQueue(label: "com.lczerniawski.framelink.camera", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.lczerniawski.framelink.encode", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var shouldRun = false
    private var rotation: CGFloat = 90
    private let encoder: VideoEncoder

    init(encoder: VideoEncoder, recentPhotos: RecentPhotoStore) {
        self.encoder = encoder
        self.recentPhotos = recentPhotos
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                               name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded),
                                               name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeError(_:)),
                                               name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() {
        sessionQueue.async {
            self.shouldRun = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    self.sessionQueue.async {
                        guard self.shouldRun else { return }
                        if allowed { self.configureAndStart() } else { self.permissionDenied() }
                    }
                }
            default: self.permissionDenied()
            }
        }
    }

    @MainActor func stop() {
        cancelTimer()
        sessionQueue.async {
            self.shouldRun = false
            if self.session.isRunning { self.session.stopRunning() }
            self.publish { $0.isReady = false; $0.status = "Camera paused" }
        }
    }

    @MainActor func switchCamera() {
        guard isReady, !isCapturing else { return }
        sessionQueue.async {
            guard self.configured, let oldInput = self.input else { return }
            self.publish { $0.isReady = false }
            let position: AVCaptureDevice.Position = oldInput.device.position == .back ? .front : .back
            do {
                guard let device = Self.preferredCamera(position: position) else {
                    throw CameraError.unavailable
                }
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.input = newInput
                } else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraError.configuration
                }
                self.configurePhotoSize()
                self.session.commitConfiguration()
                self.configureFrameRate()
                self.configureControls(reset: true)
                self.applyRotation()
                let running = self.session.isRunning && !self.session.isInterrupted
                self.publish { $0.device = device; $0.isReady = running }
            } catch {
                let running = self.session.isRunning && !self.session.isInterrupted
                self.publish { $0.isReady = running; $0.errorMessage = error.localizedDescription }
            }
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer, completion: @escaping @MainActor () -> Void) {
        sessionQueue.async {
            // SwiftUI can overlap preview surfaces; each layer must keep its own connection.
            self.session.beginConfiguration()
            layer.session = self.session
            self.session.commitConfiguration()
            self.publish { _ in completion() }
        }
    }

    func detachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            guard layer.session === self.session else { return }
            self.session.beginConfiguration()
            layer.session = nil
            self.session.commitConfiguration()
        }
    }

    func setPreviewRotation(_ angle: CGFloat, mirrored: Bool, for layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            guard layer.session === self.session, let connection = layer.connection else { return }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }

    func setRotation(_ angle: CGFloat) {
        sessionQueue.async {
            self.rotation = angle
            self.applyRotation()
        }
    }

    @MainActor func capturePhoto(timer: PhotoTimer = .off) {
        guard isReady, !isCapturing else { return }
        isCapturing = true
        status = "Preparing photo…"
        let id = UUID()
        scheduledCaptureID = id
        let flash = flashMode
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
            Task { @MainActor in
                guard self.scheduledCaptureID == id else { return }
                guard authorization == .authorized || authorization == .limited else {
                    self.scheduledCaptureID = nil
                    self.finishPhoto(error: "Allow Frame Link to add photos in Settings → Privacy & Security → Photos, then try again.")
                    return
                }
                self.countdownTask = Task { @MainActor in
                    do {
                        for second in timer.ticks {
                            self.countdown = second
                            self.status = "Photo in \(second)…"
                            if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: "\(second)") }
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch { return }
                    guard self.scheduledCaptureID == id, self.isReady else { self.cancelTimer(); return }
                    self.countdown = nil
                    self.countdownTask = nil
                    self.scheduledCaptureID = nil
                    self.status = "Taking photo…"
                    self.capturePreparedPhoto(flash: flash)
                }
            }
        }
    }

    @MainActor func cancelTimer() {
        guard scheduledCaptureID != nil else { return }
        countdownTask?.cancel()
        countdownTask = nil
        scheduledCaptureID = nil
        countdown = nil
        isCapturing = false
        status = isReady ? "Ready" : "Camera paused"
    }

    private func capturePreparedPhoto(flash: CameraFlash) {
        sessionQueue.async {
            guard self.shouldRun, self.session.isRunning, !self.session.isInterrupted else {
                self.finishPhoto(error: "The camera is unavailable. Return to Camera Mode and try again.")
                return
            }
            let mode: AVCaptureDevice.FlashMode
            switch flash {
            case .off: mode = .off
            case .auto: mode = .auto
            case .on: mode = .on
            }
            guard self.photoOutput.supportedFlashModes.contains(mode),
                  flash == .off || self.input?.device.isFlashAvailable == true else {
                self.finishPhoto(error: "Flash is unavailable. Turn it off and try again.")
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced
            settings.flashMode = mode
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    @MainActor func setFlash(_ mode: CameraFlash) {
        guard !isCapturing, flashModes.contains(mode) else { return }
        flashMode = mode
    }

    @MainActor func setZoom(_ value: Double) {
        guard isReady, !isCapturing, value.isFinite else { return }
        sessionQueue.async {
            guard self.shouldRun, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let multiplier = Double(device.displayVideoZoomFactorMultiplier)
                let range = self.availableZoomRange(device)
                let factor = CameraControlMath.clamp(value / multiplier, to: range)
                device.videoZoomFactor = CGFloat(factor)
                let applied = Double(device.videoZoomFactor) * multiplier
                self.publish { $0.zoomFactor = applied }
            } catch { self.publish { $0.errorMessage = "Zoom could not be changed: \(error.localizedDescription)" } }
        }
    }

    @MainActor func setExposure(_ value: Double) {
        guard isReady, !isCapturing, value.isFinite else { return }
        sessionQueue.async {
            guard self.shouldRun, let device = self.input?.device,
                  device.isExposureModeSupported(.continuousAutoExposure) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let bias = CameraControlMath.clamp(value, to: Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias))
                device.setExposureTargetBias(Float(bias))
                self.publish { $0.exposureBias = bias }
            } catch { self.publish { $0.errorMessage = "Exposure could not be changed: \(error.localizedDescription)" } }
        }
    }

    @MainActor func focus(at point: CGPoint) {
        guard isReady, !isCapturing, point.x.isFinite, point.y.isFinite else { return }
        let point = CGPoint(x: CameraControlMath.clamp(point.x, to: 0...1), y: CameraControlMath.clamp(point.y, to: 0...1))
        sessionQueue.async {
            guard self.shouldRun, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusPointOfInterest = point
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusPointOfInterest = point
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
            } catch { self.publish { $0.errorMessage = "Focus could not be changed: \(error.localizedDescription)" } }
        }
    }

    private func configureAndStart() {
        guard shouldRun else { return }
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .photo
                guard let camera = Self.preferredCamera(position: .back) else {
                    throw CameraError.unavailable
                }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else { throw CameraError.configuration }
                session.addInput(input)
                self.input = input
                for output in [photoOutput as AVCaptureOutput, videoOutput] {
                    guard session.canAddOutput(output) else {
                        for attached in session.outputs { session.removeOutput(attached) }
                        session.removeInput(input)
                        self.input = nil
                        throw CameraError.configuration
                    }
                    session.addOutput(output)
                }
                photoOutput.maxPhotoQualityPrioritization = .quality
                configurePhotoSize()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.automaticallyConfiguresOutputBufferDimensions = false
                videoOutput.deliversPreviewSizedOutputBuffers = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                configured = true
            }
            configureFrameRate()
            configureControls(reset: !session.isRunning)
            applyRotation()
            session.startRunning()
            let running = session.isRunning && !session.isInterrupted
            let device = input?.device
            publish {
                $0.device = device
                $0.cameraDenied = false
                $0.isReady = running
                $0.status = running ? "Ready" : "Camera unavailable"
                if !running { $0.errorMessage = "Couldn’t start the camera. Close other camera apps and tap Retry camera." }
            }
        } catch {
            publish { $0.isReady = false; $0.status = "Camera unavailable"; $0.errorMessage = error.localizedDescription }
        }
    }

    private static func preferredCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        return types.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: position) }.first
    }

    private func availableZoomRange(_ device: AVCaptureDevice) -> ClosedRange<Double> {
        let recommended = device.activeFormat.systemRecommendedVideoZoomRange
        let minimum = max(device.minAvailableVideoZoomFactor, recommended?.lowerBound ?? device.minAvailableVideoZoomFactor)
        let maximum = min(device.maxAvailableVideoZoomFactor, recommended?.upperBound ?? device.maxAvailableVideoZoomFactor)
        return Double(minimum)...Double(max(minimum, maximum))
    }

    private func configureControls(reset: Bool) {
        guard let device = input?.device else { return }
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        let range = availableZoomRange(device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if reset {
                device.videoZoomFactor = CGFloat(CameraControlMath.clamp(1 / multiplier, to: range))
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                device.setExposureTargetBias(0)
            }
        } catch { publish { $0.errorMessage = "Couldn’t set up camera controls: \(error.localizedDescription)" } }
        let displayRange = (range.lowerBound * multiplier)...(range.upperBound * multiplier)
        let factors = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            + device.activeFormat.secondaryNativeResolutionZoomFactors.map { Double($0) }
        let stops = CameraControlMath.zoomStops(range: displayRange, multiplier: multiplier, nativeFactors: factors)
        let modes: [CameraFlash] = device.hasFlash ? CameraFlash.allCases.filter { mode in
            let value: AVCaptureDevice.FlashMode = mode == .auto ? .auto : (mode == .on ? .on : .off)
            return photoOutput.supportedFlashModes.contains(value)
        } : [.off]
        let zoom = Double(device.videoZoomFactor) * multiplier
        let exposureRange = device.isExposureModeSupported(.continuousAutoExposure)
            ? Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias) : 0...0
        let bias = Double(device.exposureTargetBias)
        let metering = (device.isFocusPointOfInterestSupported && (device.isFocusModeSupported(.continuousAutoFocus) || device.isFocusModeSupported(.autoFocus)))
            || (device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure))
        publish {
            $0.zoomRange = displayRange
            $0.zoomFactor = zoom
            $0.zoomStops = stops
            $0.exposureRange = exposureRange
            $0.exposureBias = bias
            $0.supportsMetering = metering
            $0.flashModes = modes
            if !modes.contains($0.flashMode) { $0.flashMode = .off }
        }
    }

    private func configurePhotoSize() {
        guard let dimensions = input?.device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        photoOutput.maxPhotoDimensions = dimensions
    }

    private func configureFrameRate() {
        guard let device = input?.device,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 24 && $0.maxFrameRate >= 24 }) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
        } catch {
            publish { $0.errorMessage = "Could not set the preview frame rate: \(error.localizedDescription)" }
        }
    }

    private func applyRotation() {
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    private func permissionDenied() {
        publish { $0.cameraDenied = true; $0.isReady = false; $0.status = "Camera access required" }
    }

    private func publish(_ update: @escaping @MainActor (CameraManager) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    private func finishPhoto(error: String?) {
        publish {
            $0.isCapturing = false
            if let error { $0.status = "Photo not saved"; $0.errorMessage = error }
            else { $0.status = "Saved to Photos" }
        }
    }

    @objc private func interrupted() {
        publish { $0.cancelTimer(); $0.isReady = false; $0.status = "Camera interrupted. Return to Frame Link or close other camera apps." }
    }

    @objc private func interruptionEnded() {
        sessionQueue.async { if self.shouldRun { self.configureAndStart() } }
    }

    @objc private func runtimeError(_ notification: Notification) {
        publish { $0.cancelTimer(); $0.isReady = false }
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        sessionQueue.async {
            if error?.code == .mediaServicesWereReset, self.shouldRun { self.configureAndStart() }
            else {
                self.publish {
                    $0.isReady = false
                    $0.status = "Camera error"
                    $0.errorMessage = error?.localizedDescription ?? "The camera stopped unexpectedly. Tap Retry camera."
                }
            }
        }
    }

    private enum CameraError: LocalizedError {
        case unavailable, configuration
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The camera is unavailable. Close other camera apps and tap Retry camera."
            case .configuration: return "Couldn’t set up the camera. Close other camera apps and try again."
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.encode(buffer)
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { finishPhoto(error: error.localizedDescription); return }
        guard let data = photo.fileDataRepresentation() else {
            finishPhoto(error: "Couldn’t read the photo. Try taking another one.")
            return
        }
        // Full-resolution photo data stays on this iPhone and never enters the preview encoder.
        let savedIdentifier = OSAllocatedUnfairLock<String?>(initialState: nil)
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            savedIdentifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        } completionHandler: { success, error in
            guard success else {
                self.finishPhoto(error: error?.localizedDescription ?? "Couldn’t save the photo. Check free storage and Frame Link’s Photos access in Settings.")
                return
            }
            let identifier = savedIdentifier.withLock { $0 }
            Task { @MainActor in
                guard let identifier, !identifier.isEmpty else {
                    self.finishPhoto(error: nil)
                    self.errorMessage = "Saved to Photos, but Frame Link couldn’t add the photo to Recent photos."
                    return
                }
                self.recentPhotos.add(data, assetIdentifier: identifier) { self.finishPhoto(error: nil) }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { finishPhoto(error: error.localizedDescription) }
    }
}
