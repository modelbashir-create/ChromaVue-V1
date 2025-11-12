//
//  ContentView.swift
//  ChromaVue
//
//  Enhanced with iOS 18+ features and modern design patterns
//  Updated by ChatGPT to unify ContentView (camera + overlay + HUD)
//

import SwiftUI
import AVFoundation
import CoreGraphics
import UIKit

private struct CVTokens {
    static let hairline = Color.white.opacity(0.15)
    static let hudAnim: Double = 0.12
}

// Helper to choose interpolation consistently
private func currentInterpolation(_ model: ChromaModelManager) -> Image.Interpolation {
    if model.developerMode {
        switch model.interpolationMode {
        case .none: return .none
        case .low:  return .low
        case .high: return .high
        }
    } else {
        return .low
    }
}

struct ContentView: View {
    // Singletons observed (not owned) by the View
    @ObservedObject private var cam = ChromaCameraManager.shared
    @ObservedObject private var analysis = AnalysisManager.shared
    @ObservedObject private var depth = DepthManager.shared
    @ObservedObject private var model = ChromaModelManager.shared
    @ObservedObject private var export = DataExportManager.shared
    @StateObject private var startup = StartupCoordinator()
    
    @State private var showDevSheet = false
    
    // Permission handling
    @State private var showPermissionAlert = false
    
    // Bottom tab selection (Scan · History · Help · Settings)
    @State private var currentTab: AppTab = .scan

    // UI-only rotation (Dev): rotate preview overlay with device orientation
    @State private var rotateUIWithDevice: Bool = false
    @State private var uiRotationDegrees: Double = 0
    
    // iOS 18+ Environment values
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // Developer-only QC helpers
    private var isDistanceOK: Bool {
        let d = depth.meanDistanceMM
        return d >= 80 && d <= 150   // provisional capture window
    }
    private var isTiltOK: Bool {
        abs(depth.tiltDegrees) <= 10  // provisional tilt window
    }
    // Accessibility label for status pill
    private var statusAccessibilityLabel: String {
        if model.developerMode { return "Open settings" }
        return cam.isSessionRunning ? "Live status" : "Idle status"
    }

    // Hide the bottom tabs while scanning on the Scan tab
    private var shouldShowTabBar: Bool {
        !(currentTab == .scan && cam.isSessionRunning)
    }

    var body: some View {
        ZStack {
            let rotationAngle = Angle.degrees(rotateUIWithDevice ? uiRotationDegrees : 0)
            // Full-screen live camera
            cameraLayer(rotationAngle: rotationAngle)
            
            // Full-field heatmap overlay (from model scalar output), if available
            HeatmapLayer(model: model)
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.15), value: uiRotationDegrees)

            // HUD
            hudOverlay()
        }
        // Placeholder pages for non-Scan tabs
        .overlay {
            switch currentTab {
            case .history:
                HistoryPlaceholderView()
                    .transition(.opacity)
                    .id("tab.history")
            case .help:
                HelpPlaceholderView()
                    .transition(.opacity)
                    .id("tab.help")
            case .scan, .settings:
                EmptyView()
            }
        }
        // Liquid glass tab bar pinned to bottom (hidden while scanning)
        .overlay(alignment: .bottom) {
            if shouldShowTabBar {
                LiquidGlassTabBar(selection: $currentTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if startup.isBlocking {
                LaunchOverlay(startup: startup)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShowTabBar)
        .onAppear {
            startup.start()
            // Start orientation notifications (Dev toggle controls usage)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            uiRotationDegrees = mapDeviceOrientationToDegrees(UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            depth.stop()
            cam.setFlash(false)
        }
        .sheet(isPresented: $showDevSheet, onDismiss: {
            // Return to Scan after closing Settings
            currentTab = .scan
        }) {
            SettingsView()
        }
        .alert("Camera Permission Required", isPresented: $showPermissionAlert) {
            Button("Settings") {
                // Open Settings app to privacy section
                if let settingsUrl = URL(string: UIApplication.openSettingsURLString),
                   UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("ChromaVue needs camera access to capture color information from the skin and show live visual maps. Please enable camera permission in Settings > Privacy & Security > Camera.")
        }
        .onChange(of: cam.flashAlternationEnabled) { oldValue, enabled in
            if enabled { cam.setFlash(false) }
        }
        .onChange(of: export.isEnabledDev) { oldValue, enabled in
            UIAccessibility.post(notification: .announcement, argument: enabled ? "Export saving enabled." : "Export saving disabled.")
        }
        .onChange(of: export.writeCSV) { oldValue, enabled in
            UIAccessibility.post(notification: .announcement, argument: enabled ? "CSV summary enabled." : "CSV summary disabled.")
        }
        .onChange(of: export.saveHeatmapPNG) { oldValue, enabled in
            UIAccessibility.post(notification: .announcement, argument: enabled ? "Heatmap preview saving enabled." : "Heatmap preview saving disabled.")
        }
        .onChange(of: export.savePreviewJPEG) { oldValue, enabled in
            UIAccessibility.post(notification: .announcement, argument: enabled ? "Preview JPEG saving enabled." : "Preview JPEG saving disabled.")
        }
        .onChange(of: currentTab) { oldValue, newValue in
            // Open settings when the Settings tab is selected; return to Scan after dismiss
            if newValue == .settings {
                showDevSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            uiRotationDegrees = mapDeviceOrientationToDegrees(UIDevice.current.orientation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraPermissionDenied)) { _ in
            showPermissionAlert = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                if export.sessionFolder != nil {
                    export.endSession()
                    UIAccessibility.post(notification: .announcement, argument: "Export session ended when app left the foreground.")
                }
            }
        }
    }
}

// MARK: - Oxygen scale bar with live marker
struct OxygenScaleBar: View {
    var value: CGFloat   // 0...1 position
    
    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(gradient: Gradient(colors: [.blue, .white, .red]),
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 6)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            
            GeometryReader { proxy in
                let w = proxy.size.width
                let x = min(max(value, CGFloat(0)), CGFloat(1)) * w
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 1, x: 0, y: 0)
                    .offset(x: x - 5, y: -2)
            }
            .frame(width: 160, height: 10)
        }
    }
}

// MARK: - Placeholder Views

struct HistoryPlaceholderView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 40, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                Text("History")
                    .font(.title2.bold())
                Text("Your scans will appear here once you start capturing.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.horizontal, 24)
            }
        }
    }
}

struct HelpPlaceholderView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 40, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .padding(.top, 40)
                    Text("Help & Guidance")
                        .font(.title2.bold())
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Tap **Start** in the Scan tab to begin.")
                        Text("• Keep the phone steady; aim for 8–15 cm distance.")
                        Text("• Colors indicate relative oxygenation; blue tends to lower values, red to higher.")
                        Text("• Do not use this app for diagnosis or emergency decisions. If you have concerns, contact your care team.")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}

// MARK: - Split-out Heatmap layer to help the type-checker
private struct HeatmapLayer: View {
    @ObservedObject var model: ChromaModelManager

    var body: some View {
        Group {
            if let scalar = model.scalarCI {
                if model.developerMode && model.experimental3DHeatmap {
                    // Experimental 2.5D mesh view (dev-only)
                    HeatmapMesh3DView(scalarImage: scalar)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    // Existing 2D overlay
                    HeatmapOverlay(fullField: scalar,
                                   interpolation: currentInterpolation(model))
                        .environmentObject(model)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
#Preview("App Root – User") {
    let model = ChromaModelManager.shared
    model.developerMode = false
    return ContentView()
}

#Preview("App Root – Developer") {
    let model = ChromaModelManager.shared
    model.developerMode = true
    return ContentView()
}

// MARK: - Device orientation to degrees helper
private func mapDeviceOrientationToDegrees(_ o: UIDeviceOrientation) -> Double {
    switch o {
    case .portrait:            return 0
    case .landscapeRight:      return -90   // home button right → rotate CCW for view space
    case .landscapeLeft:       return 90    // home button left  → rotate CW for view space
    case .portraitUpsideDown:  return 180
    default:                   return 0
    }
}

extension ContentView {
    // MARK: - Subviews (pure SwiftUI helpers to keep body simple)
    private func cameraLayer(rotationAngle: Angle) -> some View {
        CameraPreview(session: cam.session, rotateWithDevice: $rotateUIWithDevice)
            .rotationEffect(rotationAngle)
            .animation(.easeInOut(duration: 0.15), value: uiRotationDegrees)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private func hudOverlay() -> some View {
        VStack(spacing: 12) {
            // Top-left status
            HStack(spacing: 8) {
                Circle()
                    .fill(cam.isSessionRunning ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(cam.isSessionRunning ? "LIVE" : "IDLE")
                    .font(.caption).bold()
                    .foregroundStyle(.white)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Only opens settings sheet when Developer Mode is ON.
                if model.developerMode { showDevSheet = true }
            }
            .accessibilityLabel(statusAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(cam.isSessionRunning ? "Live" : "Idle")
            .accessibilityIdentifier("status.pill")
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(6)
            .padding(.leading, 12)
            .liquidGlassCapsule()
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .animation(.easeInOut(duration: CVTokens.hudAnim), value: cam.isSessionRunning)
            
            Spacer()
            
            if model.developerMode {
                // Geometry (LiDAR) readout — developer only
                HStack(spacing: 10) {
                    Label { Text(String(format: "%.0f mm", depth.meanDistanceMM)) } icon: { Image(systemName: "ruler") }
                        .font(.caption2)
                        .foregroundStyle(.white)
                    Label { Text(String(format: "%.0f°", depth.tiltDegrees)) } icon: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                        .font(.caption2)
                        .foregroundStyle(.white)
                    Label { Text(String(format: "Conf %.1f", depth.confidence)) } icon: { Image(systemName: "gauge") }
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Geometry")
                .accessibilityValue("\(Int(depth.meanDistanceMM)) millimeters, \(Int(depth.tiltDegrees)) degrees tilt, confidence \(String(format: "%.1f", depth.confidence))")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .liquidGlassCapsule()
                .clipShape(Capsule())
            }

            if model.developerMode {
                // Live Analysis block — developer only
                VStack(spacing: 2) {
                    Text("Live Analysis")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan.opacity(0.9))
                    Divider()
                        .frame(width: 120)
                        .background(.cyan.opacity(0.7))
                    HStack {
                        Text(String(format: "R̄: %.1f", analysis.meanR))
                        Text(String(format: "Ḡ: %.1f", analysis.meanG))
                        Text(String(format: "log₁₀(R/G): %.3f", analysis.logRG))
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.95))
                    
                    // O₂ scale with live marker (mapped from logRG)
                    let v = analysis.logRG
                    let clamped = max(-0.30, min(0.30, v))
                    let oxyValue = CGFloat((clamped + 0.30) / 0.60)
                    OxygenScaleBar(value: oxyValue)
                        .accessibilityLabel("Oxygenation scale with live marker")
                    
                    // Developer-only model status badge
                    if model.developerMode {
                        Text("Model: \(model.isLoaded ? "Loaded" : "Stub")")
                            .font(.caption2)
                            .foregroundStyle(model.isLoaded ? .green : .orange)
                            .padding(.top, 2)
                    }
                    // Developer-only heatmap source badge
                    if model.developerMode {
                        let src: String = {
                            switch model.heatmapSource {
                            case .coreml:   return "Heatmap Source: CoreML"
                            case .analytic: return "Heatmap Source: Analytic"
                            case .auto:     return model.isLoaded ? "Heatmap Source: Auto → CoreML" : "Heatmap Source: Auto → Analytic"
                            }
                        }()
                        Text(src)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    // Developer-only CoreML stats (only when CoreML is active)
                    if model.developerMode,
                       (model.heatmapSource == .coreml || (model.heatmapSource == .auto && model.isLoaded)) {
                        HStack(spacing: 12) {
                            if let mean = model.sto2Mean {
                                Text(String(format: "StO₂ mean: %.0f%%", mean))
                            } else {
                                Text("StO₂ mean: —")
                            }
                            if let ms = model.inferenceMS {
                                Text(String(format: "CoreML: %.1f ms", ms))
                            } else {
                                Text("CoreML: — ms")
                            }
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityIdentifier("dev.coreml.stats")
                    }
                }
                .padding(.horizontal, 12)
            }

            // Controls
            HStack(spacing: 10) {
                Button {
                    let gen = UIImpactFeedbackGenerator(style: .light)
                    gen.impactOccurred()
                    cam.isSessionRunning ? cam.stopSession() : cam.startSession()
                } label: {
                    Label(cam.isSessionRunning ? "Stop" : "Start",
                          systemImage: cam.isSessionRunning ? "stop.circle.fill" : "play.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .liquidGlassCapsule()
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .contentShape(Rectangle())
                        .animation(.easeInOut(duration: CVTokens.hudAnim), value: cam.isSessionRunning)
                }
                .padding(.vertical, 2)
                
                // Inline RAW button (dev export only)
                if model.developerMode && export.isEnabledDev {
                    Button {
                        let gen = UIImpactFeedbackGenerator(style: .rigid)
                        gen.impactOccurred()
                        ChromaCameraManager.shared.captureRawPlusHEICStill()
                    } label: {
                        Text("RAW")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .liquidGlassCapsule()
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                            .accessibilityHint("Saves a RAW still. Success haptic on save.")
                    }
                    .disabled(!cam.isSessionRunning)
                    .accessibilityLabel("Capture RAW still")
                    .accessibilityIdentifier("btn.dev.raw.inline")
                }

                Button {
                    cam.setFlash(!cam.isFlashOn)
                } label: {
                    Label(cam.isFlashOn ? "Flash On" : "Flash Off",
                          systemImage: cam.isFlashOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .liquidGlassCapsule()
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .contentShape(Rectangle())
                        .accessibilityHint((cam.isFlashAvailable && !cam.flashAlternationEnabled) ? "" : "Dimmed")
                        .animation(.easeInOut(duration: CVTokens.hudAnim), value: cam.isFlashOn)
                }
                .disabled(!cam.isFlashAvailable || cam.flashAlternationEnabled)
                .opacity((cam.isFlashAvailable && !cam.flashAlternationEnabled) ? 1.0 : 0.5)
            }
            .buttonStyle(.plain)

            // Developer-only capture bar (below controls, above bottom padding)
            if model.developerMode {
                HStack(spacing: 10) {
                    // FPS chip (developer only)
                    Text(String(format: "%.1f FPS", analysis.fps))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .liquidGlassCapsule()
                        .clipShape(Capsule())

                    // REC badge to indicate training export status
                    let isRecording = (export.sessionFolder != nil)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isRecording ? Color.green : Color.gray.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text("REC")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .liquidGlassCapsule()
                    .clipShape(Capsule())
                    .accessibilityLabel(isRecording ? "Recording export is active" : "Recording export is inactive")

                    // Start/End Export session
                    Button {
                        if export.sessionFolder == nil {
                            export.beginNewSession()
                            UIAccessibility.post(notification: .announcement, argument: "Export session started.")
                        } else {
                            export.endSession()
                            UIAccessibility.post(notification: .announcement, argument: "Export session ended.")
                        }
                    } label: {
                        Label(export.sessionFolder == nil ? "Start Export" : "End Export",
                              systemImage: export.sessionFolder == nil ? "record.circle" : "stop.circle")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .liquidGlassCapsule()
                            .clipShape(Capsule())
                    }
                    .accessibilityIdentifier("btn.dev.export")

                    // Pairing indicator (flash alternation)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(cam.flashAlternationEnabled ? Color.orange : Color.gray.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text(cam.flashAlternationEnabled ? "Pairing ON" : "Pairing OFF")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .liquidGlassCapsule()
                    .clipShape(Capsule())

                    // QC badges (distance/tilt)
                    HStack(spacing: 8) {
                        Label(isDistanceOK ? "Dist OK" : "Dist!", systemImage: isDistanceOK ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(isDistanceOK ? .green : .yellow)
                        Label(isTiltOK ? "Tilt OK" : "Tilt!", systemImage: isTiltOK ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(isTiltOK ? .green : .yellow)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .liquidGlassCapsule()
                    .clipShape(Capsule())

                    // Mark Event (developer JSONL)
                    Button {
                        let ts = Int(Date().timeIntervalSince1970)
                        export.appendEvent(name: "mark", note: "User marker @ \(ts)")
                    } label: {
                        Label("Mark Event", systemImage: "flag.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .liquidGlassCapsule()
                            .clipShape(Capsule())
                    }
                    .accessibilityIdentifier("btn.dev.markevent")
                }
            }
        }
        .padding(.bottom, 20)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }
}
