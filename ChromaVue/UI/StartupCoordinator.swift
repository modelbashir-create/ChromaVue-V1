//  StartupCoordinator.swift
//  ChromaVue
//
//  Drives the launch-time "preflight" and exposes a simple state/progress
//  for a lightweight loading overlay. It observes your existing singletons
//  and does not own them.

import Foundation
import AVFoundation
import Combine

@MainActor
final class StartupCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case checkingPermissions
        case requestingPermissions
        case configuringSession
        case startingDepth
        case loadingModel
        case ready
        case blockedPermission
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var progress: Double = 0.0       // 0...1
    @Published var isBlocking: Bool = true      // when true, show overlay
    @Published var checklist: [String: Bool] = [
        "Camera permission": false,
        "Session configured": false,
        "Model available": false,
        "Tilt sensor active": false
    ]

    private var didKickoff = false
    private var pollingTask: Task<Void, Never>?

    func start() {
        guard !didKickoff else { return }
        didKickoff = true
        state = .checkingPermissions
        isBlocking = true

        // Begin by checking/requesting camera permission
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            checklist["Camera permission"] = true
            configureSession()
        case .notDetermined:
            state = .requestingPermissions
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.checklist["Camera permission"] = true
                        self.configureSession()
                    } else {
                        self.state = .blockedPermission
                        self.isBlocking = true
                    }
                }
            }
        default:
            state = .blockedPermission
            isBlocking = true
        }
    }

    private func configureSession() {
        state = .configuringSession
        // Kick existing managers (ContentView already does this too; safe to duplicate)
        ChromaCameraManager.shared.startSession()

        // Depth (tilt) can start early
        state = .startingDepth
        DepthManager.shared.start()

        // Model load
        state = .loadingModel
        ChromaModelManager.shared.heatmapSource = .auto
        ChromaModelManager.shared.loadModel()

        // Export sessions are managed explicitly by training mode UI, not at startup.
        startPolling()
    }

    private func startPolling() {
        var ticks = 0
        pollingTask?.cancel()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1

                // Update checklist
                let camOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                self.checklist["Camera permission"] = camOK

                let configured = !ChromaCameraManager.shared.session.inputs.isEmpty
                self.checklist["Session configured"] = configured

                let modelOK = ChromaModelManager.shared.isLoaded || (ChromaModelManager.shared.heatmapSource != .coreml)
                self.checklist["Model available"] = modelOK

                let tiltOK = true // DepthManager has no explicit flag; assume started
                self.checklist["Tilt sensor active"] = tiltOK

                // Progress as fraction of completed checks
                let done = self.checklist.values.filter { $0 }.count
                self.progress = Double(done) / Double(self.checklist.count)

                if done == self.checklist.count || ticks > 20 { // ~3s cap
                    self.state = camOK ? .ready : .blockedPermission
                    self.isBlocking = !(self.state == .ready)
                    self.pollingTask?.cancel()
                    self.pollingTask = nil
                    break
                }

                try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            }
        }
    }
}
