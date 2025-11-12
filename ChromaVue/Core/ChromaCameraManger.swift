//
//  ChromaCameraConfig.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/4/25.
//


//
//  ChromaCameraManager.swift
//  ChromaVue
//
//  Modern Swift 6–safe camera manager.
//  - Owns AVFoundation session, torch, orientation.
//  - Forwards frames to AnalysisManager (math engine) and ChromaModelManager.
//  - Optional RAW still capture for training.
//  - No per-frame band / pairing / ΔI / log math here.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import UIKit
import Combine

/// Simple configuration for camera behavior.
struct ChromaCameraConfig: Equatable {
    /// Allowed ON/OFF pairing window in ms (used by AnalysisManager logic).
    let pairWindowMS: Int64
    /// Reserved for future subsampling control in AnalysisManager.
    let sampleStride: Int

    static let `default` = ChromaCameraConfig(pairWindowMS: 120, sampleStride: 2)
}

/// Box wrapper to move CMSampleBuffer across tasks. AVFoundation sample buffers are
/// designed to be used across queues, so we mark this as @unchecked Sendable.
struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

/// Clock abstraction in case you want to mock time in tests.
protocol ClockProviding {
    func nowMS() -> Int64
}

extension ClockProviding {
    func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private struct DefaultClock: ClockProviding {}

/// Main camera manager for ChromaVue.
/// - Not @MainActor isolated: AVFoundation work runs on dedicated queues.
/// - UI-facing state is updated on the main actor via `@Published` + main thread hops.
final class ChromaCameraManager: NSObject, ObservableObject {

    // MARK: - Shared instance

    /// Overridable shared instance for dependency injection / testing.
    static var shared = ChromaCameraManager(config: .default)

    // MARK: - Configuration & dependencies

    private let config: ChromaCameraConfig
    private let clock: ClockProviding

    // MARK: - AVFoundation session & outputs

    /// Dedicated queue for session configuration and start/stop.
    private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInitiated)
    /// Dedicated queue for video output callbacks.
    private let videoQueue  = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var deviceInput: AVCaptureDeviceInput?

    /// Delegate proxy to bridge AVFoundation callbacks into our manager.
    private lazy var delegateProxy = VideoOutputProxy(owner: self)

    // MARK: - UI preview orientation

    private struct WeakLayer {
        weak var value: AVCaptureVideoPreviewLayer?
    }

    private var attachedPreviewLayers: [WeakLayer] = []
    private var orientationObserver: NSObjectProtocol?

    // MARK: - Flash & alternation state

    private enum FlashState { case on, off }

    /// High-level flash mode used by app logic (Clinical vs Training).
    enum FlashMode {
        case off
        case on
        case alternating
    }

    /// Internal flash state used when alternation is enabled.
    private var flashState: FlashState = .off

    /// Monotonic frame index (useful for debugging / export correlation).
    private var frameIndex: Int = 0

    /// Session-relative zero point in ms, used for timeline passed into analysis/export.
    private var sessionStartMS: Int64?

    // MARK: - Still capture

    /// Retains delegates until capture completes.
    private var inflightPhotoDelegates: [PhotoCaptureProcessor] = []

    // MARK: - Published UI-facing properties

    /// Latest raw buffer for debug preview use (e.g., a small dev view).
    @Published private(set) var latestBuffer: CMSampleBuffer?

    @Published var isSessionRunning: Bool = false
    @Published var isFlashAvailable: Bool = false
    @Published var isFlashOn: Bool = false
    /// When true, camera alternates flash (LED) ON/OFF per frame; manual flash is disabled.
    @Published var flashAlternationEnabled: Bool = false

    /// If true, RAW DNG stills are written when capturing Training stills.
    @Published var saveRawStill: Bool = true

    /// If true, when capturing RAW we also save a HEIC sidecar for context.
    @Published var saveHEICSidecar: Bool = true

    // MARK: - Init / deinit

    init(config: ChromaCameraConfig, clock: ClockProviding = DefaultClock()) {
        self.config = config
        self.clock = clock
        super.init()

        #if canImport(UIKit)
        // Device orientation notifications must be started/stopped on main actor.
        Task { @MainActor in
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }

        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyCurrentOrientationToAttachedLayers()
        }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        if let obs = orientationObserver {
            NotificationCenter.default.removeObserver(obs)
            orientationObserver = nil
        }
        Task { @MainActor in
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        #endif
    }

    // MARK: - Permission helpers

    private func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func requestCameraPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            requestCameraPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Public API: Session control

    /// Start the camera capture session, requesting permission if needed.
    func startSession() {
        guard !isSessionRunning else { return }

        Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestCameraPermission()
            if !granted {
                await MainActor.run { self.handlePermissionDenied() }
                return
            }

            // Establish a session-relative zero point for timestamps.
            if self.sessionStartMS == nil {
                self.sessionStartMS = self.clock.nowMS()
            }

            // Configure session once, then start running on the session queue.
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.configureSessionIfNeeded()
                self.session.startRunning()
                Task { @MainActor in
                    self.setSessionRunning(true)
                    self.updateFlashAvailability()
                }
            }
        }
    }

    /// Stop the camera capture session.
    func stopSession() {
        guard isSessionRunning else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            Task { @MainActor in
                // When stopping session, also turn flash (LED) off.
                await self.setFlashHardware(on: false)
                self.setSessionRunning(false, flashOn: false)
            }
            // Reset session-relative timeline.
            self.sessionStartMS = nil
        }
    }

    // MARK: - Timeline helper

    /// Returns the current time in ms relative to the camera session start.
    /// If the session has not started yet, this falls back to wall-clock ms.
    func sessionRelativeMS() -> Int64 {
        let now = clock.nowMS()
        if let start = sessionStartMS {
            return max(0, now - start)
        } else {
            return now
        }
    }


    // MARK: - Preview layer (UI-only rotation)

    /// Attach and configure a preview layer for UI rotation only.
    /// Analysis/export remain in canonical portrait (90°) for consistency.
    func attachPreviewLayerForUIRotation(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = self.session
        layer.videoGravity = .resizeAspectFill

        // Track weakly
        attachedPreviewLayers.removeAll { $0.value == nil }
        if !attachedPreviewLayers.contains(where: { $0.value === layer }) {
            attachedPreviewLayers.append(WeakLayer(value: layer))
        }

        applyCurrentOrientation(to: layer)
    }

    /// Detach preview layer from orientation tracking.
    func detachPreviewLayerFromUIRotation(_ layer: AVCaptureVideoPreviewLayer) {
        attachedPreviewLayers.removeAll { $0.value == nil || $0.value === layer }
    }

    /// Apply current device orientation to all attached preview layers.
    private func applyCurrentOrientationToAttachedLayers() {
        attachedPreviewLayers.removeAll { $0.value == nil }
        for weakRef in attachedPreviewLayers {
            if let layer = weakRef.value {
                applyCurrentOrientation(to: layer)
            }
        }
    }

    /// Map UIDeviceOrientation to videoRotationAngle (modern API).
    private func applyCurrentOrientation(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }

        #if canImport(UIKit)
        let portrait: CGFloat       = 90
        let landscapeRight: CGFloat = 0
        let landscapeLeft: CGFloat  = 180
        let upsideDown: CGFloat     = 270

        let o = UIDevice.current.orientation
        let angle: CGFloat
        switch o {
        case .portrait:
            angle = portrait
        case .landscapeRight:
            angle = landscapeRight
        case .landscapeLeft:
            angle = landscapeLeft
        case .portraitUpsideDown:
            angle = upsideDown
        default:
            angle = portrait
        }

        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        #else
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        #endif
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        // Input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            print("⚠️ No back wide angle camera.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                self.deviceInput = input
            }
        } catch {
            print("⚠️ Failed to create device input: \(error)")
            return
        }

        // Video output
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: kCVPixelFormatType_32BGRA)
            ]
            videoOutput.setSampleBufferDelegate(delegateProxy, queue: videoQueue)
            session.addOutput(videoOutput)
        }

        // Photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        updateFlashAvailability()
        configureInitialDeviceSettings()
    }

    private func configureInitialDeviceSettings() {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            print("⚠️ Failed to configure camera: \(error)")
        }
    }

    private func updateFlashAvailability() {
        if let device = deviceInput?.device {
            isFlashAvailable = device.hasTorch
        } else {
            isFlashAvailable = false
        }
    }

    private func handlePermissionDenied() {
        NotificationCenter.default.post(name: .cameraPermissionDenied, object: nil)
    }
    // MARK: - Flash (LED) control
    /// Apply a high-level flash mode from app settings.
    /// - off:        flash off, no alternation
    /// - on:         flash on, no alternation
    /// - alternating:flash alternates ON/OFF per frame
    func applyFlashMode(_ mode: FlashMode) {
        switch mode {
        case .off:
            setFlashAlternationEnabled(false)
            setFlash(false)
        case .on:
            setFlashAlternationEnabled(false)
            setFlash(true)
        case .alternating:
            setFlashAlternationEnabled(true)
        }
    }

    /// Public flash setter for manual control.
    /// When alternation is enabled, this is ignored (alternation owns flash).
    func setFlash(_ on: Bool) {
        guard !flashAlternationEnabled else { return } // alternation owns flash

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.setFlashHardware(on: on)
            self.isFlashOn = on
        }
    }

    /// Enable/disable automatic per-frame flash alternation.
    /// When enabled:
    /// - Manual flash control is ignored.
    /// - Flash toggles ON/OFF per frame in `receive(box:)`.
    func setFlashAlternationEnabled(_ enabled: Bool) {
        flashAlternationEnabled = enabled
        frameIndex = 0
        flashState = .off

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !enabled {
                await self.setFlashHardware(on: false)
                self.isFlashOn = false
            }
        }
    }

    /// Internal low-level flash configuration (backed by AVCaptureDevice.torch).
    /// Always called on the main actor.
    @MainActor
    private func setFlashHardware(on: Bool) async {
        guard let device = deviceInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            print("⚠️ Flash configuration failed: \(error)")
        }
    }
    // MARK: - Central per-frame handler

    /// Main-actor per-frame entry point from the video delegate.
    /// - Forwards frames + metadata into AnalysisManager and ChromaModelManager.
    @MainActor
    func receive(box: SampleBufferBox) async {
        latestBuffer = box.buffer
        frameIndex &+= 1

        guard let pb = CMSampleBufferGetImageBuffer(box.buffer) else { return }

        // Determine flash state for analysis (alternation or manual)
        let flashOnForAnalysis: Bool
        if flashAlternationEnabled {
            // Toggle internal flash state per frame and update hardware.
            flashState = (flashState == .on) ? .off : .on
            await setFlashHardware(on: flashState == .on)
            isFlashOn = (flashState == .on)
            flashOnForAnalysis = (flashState == .on)
        } else {
            flashOnForAnalysis = isFlashOn
        }

        // Depth metadata (if available)
        let distanceMM = DepthManager.shared.meanDistanceMM
        let tiltDeg    = DepthManager.shared.tiltDegrees

        // Session-relative timestamp for analysis/export, owned by the camera manager.
        let now = clock.nowMS()
        let ts: Int64
        if let start = sessionStartMS {
            ts = max(0, now - start)
        } else {
            ts = now
        }

        // 1) Math engine: all band / pairing / scalar fields belong in AnalysisManager.
        AnalysisManager.shared.process(
            pixelBuffer: pb,
            flashOn: flashOnForAnalysis,
            timestampMS: ts
        )

        // 2) Model layer: analytic vs CoreML inference handled inside ChromaModelManager.
        ChromaModelManager.shared.infer(
            pixelBuffer: pb,
            distanceMM: distanceMM,
            tiltDeg: tiltDeg
        )

        // 3) Export:
        //    The modern design is: AnalysisManager + DataExportManager cooperate
        //    to build and append ExportFrameRecord using the latest metrics.
        //    If you still want CameraManager to trigger appends, you can call a
        //    helper here such as:
        //
        //    AnalysisManager.shared.exportCurrentFrame(
        //        timestampMS: ts,
        //        frameIndex: frameIndex,
        //        flashPhaseOn: flashOnForAnalysis,
        //        distanceMM: distanceMM,
        //        tiltDeg: tiltDeg
        //    )
        //
        //    and let that method talk to DataExportManager.
    }

    // MARK: - UI state helpers

    @MainActor
    private func setSessionRunning(_ running: Bool, flashOn: Bool? = nil) {
        isSessionRunning = running
        if let flashOn {
            isFlashOn = flashOn
        }
    }

    // MARK: - Still capture API

    /// Capture a RAW still with an optional HEIC sidecar, suitable for Training Mode.
    /// The captured files are written by PhotoCaptureProcessor into the current
    /// DataExportManager session folder.
    func captureRawPlusHEICStill() {
        let settings: AVCapturePhotoSettings

        if let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first {
            // Request RAW + processed HEVC (HEIC) sidecar.
            let processedFormat: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType,
                                              processedFormat: processedFormat)
        } else {
            // Fallback: capture a processed HEVC/JPEG if RAW is not available.
            settings = AVCapturePhotoSettings()
        }

        let processor = PhotoCaptureProcessor(saveHEIC: saveHEICSidecar) { [weak self] proc in
            // Drop strong reference when capture is finished.
            self?.inflightPhotoDelegates.removeAll { $0 === proc }
        }

        inflightPhotoDelegates.append(processor)
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }
}

// MARK: - Delegate proxy

/// Nonisolated proxy to bridge AVFoundation video callbacks into ChromaCameraManager.
final class VideoOutputProxy: NSObject {
    weak var owner: ChromaCameraManager?

    init(owner: ChromaCameraManager) {
        self.owner = owner
    }
}

extension VideoOutputProxy: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let box = SampleBufferBox(sampleBuffer)
        // Hop onto the main actor for UI-facing state + analysis pipeline.
        Task { @MainActor [weak weakSelf = self, box] in
            guard let owner = weakSelf?.owner else { return }
            await owner.receive(box: box)
        }
    }
}

// MARK: - Still photo delegate (RAW + optional JPEG)

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let saveHEIC: Bool
    private var rawData: Data?
    private var heicData: Data?
    private let finish: (PhotoCaptureProcessor) -> Void

    init(saveHEIC: Bool, finish: @escaping (PhotoCaptureProcessor) -> Void) {
        self.saveHEIC = saveHEIC
        self.finish = finish
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let err = error {
            print("⚠️ Photo processing error: \(err)")
            return
        }

        // When capturing RAW + processed, AVFoundation delivers two AVCapturePhoto callbacks:
        // one where `isRawPhoto == true` (DNG) and one where it is false (processed HEIC).
        if photo.isRawPhoto {
            if let data = photo.fileDataRepresentation() {
                rawData = data
            }
        } else if saveHEIC {
            if let data = photo.fileDataRepresentation() {
                heicData = data
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        defer { finish(self) }
        if let err = error {
            print("⚠️ Photo capture error: \(err)")
            return
        }

        guard let folder = DataExportManager.shared.sessionFolder else { return }
        let stills = folder.appendingPathComponent("stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)

        // Use the camera session timeline so RAW/HEIC stills share the same time base
        // as live analysis frames in frames.jsonl.
        let tms = ChromaCameraManager.shared.sessionRelativeMS()

        // Respect camera manager toggles for RAW / HEIC saving.
        if ChromaCameraManager.shared.saveRawStill, let raw = rawData {
            let url = stills.appendingPathComponent("still_\(tms)ms.dng")
            do {
                try raw.write(to: url, options: .atomic)
                DataExportManager.shared.appendEvent(timestampMS: tms,
                                                     name: "raw_still",
                                                     note: url.lastPathComponent)
            } catch {
                print("⚠️ DNG write failed: \(error)")
            }
        }

        if ChromaCameraManager.shared.saveHEICSidecar, saveHEIC, let heic = heicData {
            let url = stills.appendingPathComponent("still_\(tms)ms.heic")
            do {
                try heic.write(to: url, options: .atomic)
                DataExportManager.shared.appendEvent(timestampMS: tms,
                                                     name: "heic_sidecar",
                                                     note: url.lastPathComponent)
            } catch {
                print("⚠️ HEIC write failed: \(error)")
            }
        }
    }
}
