//
//  ModelManager.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 10/31/25.
//

//
//  ModelManager.swift
//  ChromaVue
//

import SwiftUI
import Combine
import CoreML
import Vision
import Foundation
import CoreImage
import CoreGraphics
import AVFoundation

enum HeatmapColorMap: String, CaseIterable, Identifiable, Codable {
    case blueWhiteRed
    case grayscale
    // You can add more later, e.g. case viridis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blueWhiteRed: return "Blue–White–Red"
        case .grayscale:    return "Grayscale"
        }
    }
}
struct HeatmapConfiguration: Equatable, Codable {
    var colorMap: HeatmapColorMap = .blueWhiteRed
    var opacity: CGFloat = 0.35
}

/// Handles full-field StO₂ inference -> per-pixel scalar CIImage [0,1].
@MainActor final class ChromaModelManager: ObservableObject {
    static let shared = ChromaModelManager()
    private init() {}

    // Published scalar map for the overlay (normalized 0…1)
    @Published var scalarCI: CIImage?
    // Shared configuration for heatmap visualization (used by HeatmapOverlay & EnhancedHeatMapView)
    @Published var heatmapConfig = HeatmapConfiguration()
    /// Called by AnalysisManager when a new preview scalar map is ready
    func updateScalarCI(_ ci: CIImage) {
        self.scalarCI = ci
    }

    /// Optional helper: build scalarCI from an analytic scalar grid (e.g. 64×64 log(R/G) or log(ΔR/ΔG)).
    /// This keeps CIImage construction inside the model manager so the rest of the app can work in pure numbers.
    func updateAnalyticScalarGrid(_ grid: [Float], side: Int, lo: Float = -0.30, hi: Float = 0.30) {
        guard side > 0, grid.count == side * side else { return }

        var bytes = [UInt8](repeating: 0, count: grid.count)
        let denom = max(1e-9, hi - lo)
        let scale = 1.0 / denom

        for i in 0..<grid.count {
            let v = (grid[i] - lo) * scale
            let clamped = min(1.0, max(0.0, Double(v)))
            bytes[i] = UInt8(round(clamped * 255.0))
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let cg = CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: cs,
            bitmapInfo: CGBitmapInfo(),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        let ci = CIImage(cgImage: cg)
        self.scalarCI = ci
    }
    // Developer-only diagnostics (toggled off for production)
    @Published var isLoaded: Bool = false
    @Published var developerMode: Bool = true

    // UI-only rotation controls for preview & overlay (Camera 2.0)
    @Published var rotatePreviewUI: Bool = false   // keep OFF by default; analysis/export stay portrait
    @Published var uiRotationDeg: Int = 90         // UI rotation angle (0/90/180/270)
    @Published var mirrorPreviewUI: Bool = false   // mirror only for front camera UI familiarity

    // Interpolation mode for heatmap rendering (used by HeatmapOverlay / UI)
    enum Interp: String, CaseIterable { case none, low, high }
    @Published var interpolationMode: Interp = .low

    // Heatmap source selection (developer toggle)
    enum Source: String, CaseIterable { case analytic, coreml, auto }
    @Published var heatmapSource: Source = .auto

    /// Dev-only flag to render an experimental 3D heatmap (e.g. SceneKit mesh)
    @Published var experimental3DHeatmap: Bool = false

    // Inference diagnostics for export/HUD
    @Published var sto2Min: Double? = nil
    @Published var sto2Mean: Double? = nil
    @Published var sto2Max: Double? = nil
    @Published var inferenceMS: Double? = nil
    
    // Camera 2.0: orientation metadata for UI/export (analysis stays in portrait)
    @Published var orientationDeg: Int = 90
    func updateOrientation(_ deg: Int) {
        // normalize to [0,360)
        let d = ((deg % 360) + 360) % 360
        orientationDeg = d
    }

    // Explicit setters for UI rotation (used by ContentView)
    func setRotatePreviewUI(_ on: Bool) { rotatePreviewUI = on }
    func setUIRotationDeg(_ deg: Int) {
        let d = ((deg % 360) + 360) % 360
        uiRotationDeg = d
    }
    func setMirrorPreviewUI(_ on: Bool) { mirrorPreviewUI = on }


#if canImport(CoreML)
    // Replace `Sto2FullField` with your generated model class name after you add the .mlmodel
    private var coreMLModel: MLModel?
    private var vnModel: VNCoreMLModel?

    // Auto-mode health check
    private var mlFailureCount = 0
    private let mlFailureThreshold = 3

    private var useDirectCoreML: Bool = true
    private var directFailureCount = 0

    func loadModel() {
    #if canImport(CoreML)
        // Try to locate any compiled CoreML model (.mlmodelc) bundled with the app
        if let urls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil),
           let first = urls.first {
            do {
                let model = try MLModel(contentsOf: first, configuration: mlConfig)
                self.coreMLModel = model
                self.vnModel = try VNCoreMLModel(for: model)
                self.isLoaded = true
            } catch {
                // print("CoreML load failed: \(error)")
                self.coreMLModel = nil
                self.vnModel = nil
                self.isLoaded = false
            }
        } else {
            self.coreMLModel = nil
            self.vnModel = nil
            self.isLoaded = false
        }
    #endif
    }

    private var mlConfig: MLModelConfiguration {
        let c = MLModelConfiguration()
        c.computeUnits = .all // ANE + GPU + CPU
        c.allowLowPrecisionAccumulationOnGPU = true
        return c
    }
#endif

    /// Public entry: run inference on the latest camera frame + optional aux maps (distance/tilt).
    func infer(pixelBuffer: CVPixelBuffer,
               distanceMM: Float? = nil,
               tiltDeg: Float? = nil) {
#if canImport(CoreML)
        switch heatmapSource {
        case .analytic:
            // AnalysisManager supplies scalarCI; do not override here
            return
        case .coreml:
            if useDirectCoreML, coreMLModel != nil {
                runCoreMLDirect(pixelBuffer: pixelBuffer, distanceMM: distanceMM, tiltDeg: tiltDeg)
                return
            }
            if vnModel != nil {
                runCoreML(pixelBuffer: pixelBuffer, distanceMM: distanceMM, tiltDeg: tiltDeg)
            } else {
                // Developer convenience: show stub if CoreML not yet loaded
                stubPreview(pixelBuffer: pixelBuffer)
            }
            return
        case .auto:
            if coreMLModel != nil && directFailureCount < mlFailureThreshold {
                runCoreMLDirect(pixelBuffer: pixelBuffer, distanceMM: distanceMM, tiltDeg: tiltDeg)
                return
            } else if vnModel != nil && mlFailureCount < mlFailureThreshold {
                runCoreML(pixelBuffer: pixelBuffer, distanceMM: distanceMM, tiltDeg: tiltDeg)
                return
            } else {
                // fall back: leave analytic path in control
                return
            }
        }
#else
        _ = distanceMM; _ = tiltDeg
        return
#endif
    }

#if canImport(CoreML)
    // MARK: - Core ML inference path (Vision)
    private func runCoreML(pixelBuffer: CVPixelBuffer,
                           distanceMM: Float?,
                           tiltDeg: Float?) {
        guard let vnModel = vnModel else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let req = VNCoreMLRequest(model: vnModel) { [weak self] req, _ in
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

            // Case A: MLMultiArray heatmap
            if let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
               let arr = obs.featureValue.multiArrayValue,
               let out = Self.ciImageAndStats(from: arr) {

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.mlFailureCount = 0
                    self.scalarCI = out.image
                    self.inferenceMS = dt
                    // Assuming array is 0..1 where 1 ≈ 100% StO₂; scale to percent
                    self.sto2Min = out.min * 100.0
                    self.sto2Mean = out.mean * 100.0
                    self.sto2Max = out.max * 100.0
                }
                return
            }

            // Case B: PixelBuffer output
            if let io = req.results?.first as? VNPixelBufferObservation {
                let ci = CIImage(cvPixelBuffer: io.pixelBuffer)
                let stats = Self.statsForGray(pixelBuffer: io.pixelBuffer)

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.mlFailureCount = 0
                    self.scalarCI = ci
                    self.inferenceMS = dt
                    if let s = stats {
                        self.sto2Min = s.min * 100.0
                        self.sto2Mean = s.mean * 100.0
                        self.sto2Max = s.max * 100.0
                    } else {
                        self.sto2Min = nil
                        self.sto2Mean = nil
                        self.sto2Max = nil
                    }
                }
                return
            }

            // Unknown output; count as a failure (auto-mode will fall back after a few)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mlFailureCount &+= 1
            }
        }

        req.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch {
            // print("VN perform error:", error)
        }
    }

    private func runCoreMLDirect(pixelBuffer: CVPixelBuffer,
                                 distanceMM: Float?,
                                 tiltDeg: Float?) {
        guard let model = coreMLModel else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        // Build feature provider with pixelBuffer input. Assume the model has a single image input named "image" or similar.
        // We will try common names and fall back to the first image input.
        let inputDesc = model.modelDescription.inputDescriptionsByName
        let inputName: String = inputDesc.keys.first(where: { $0.lowercased().contains("image") || $0.lowercased().contains("input") }) ?? inputDesc.keys.first ?? ""
        guard !inputName.isEmpty else { return }

        let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        guard let p = provider else { directFailureCount &+= 1; return }

        do {
            let out = try model.prediction(from: p)
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            // Try to resolve the first output as either a multiArray or pixelBuffer
            if let key = out.featureNames.first {
                let fv = out.featureValue(for: key)
                if let arr = fv?.multiArrayValue, let result = Self.ciImageAndStats(from: arr) {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.directFailureCount = 0
                        self.scalarCI = result.image
                        self.inferenceMS = dt
                        self.sto2Min = result.min * 100.0
                        self.sto2Mean = result.mean * 100.0
                        self.sto2Max = result.max * 100.0
                    }
                    return
                }
                if let pb = fv?.imageBufferValue {
                    let ci = CIImage(cvPixelBuffer: pb)
                    let stats = Self.statsForGray(pixelBuffer: pb)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.directFailureCount = 0
                        self.scalarCI = ci
                        self.inferenceMS = dt
                        if let s = stats {
                            self.sto2Min = s.min * 100.0
                            self.sto2Mean = s.mean * 100.0
                            self.sto2Max = s.max * 100.0
                        } else {
                            self.sto2Min = nil
                            self.sto2Mean = nil
                            self.sto2Max = nil
                        }
                    }
                    return
                }
            }
            // Unknown output shape; count as failure
            self.directFailureCount &+= 1
        } catch {
            self.directFailureCount &+= 1
        }
    }

    /// Convert a 2D (H×W) or 3D (C×H×W with C==1) array into a CIImage [0,1] and compute min/mean/max.
    private static func ciImageAndStats(from array: MLMultiArray) -> (image: CIImage, min: Double, mean: Double, max: Double)? {
        guard array.count > 0 else { return nil }

        // Resolve shape as H×W
        let rank = array.shape.count
        let w = rank >= 2 ? array.shape[rank - 1].intValue : Int(sqrt(Double(array.count)))
        let h = rank >= 2 ? array.shape[rank - 2].intValue : w
        let bytesPerRow = w

        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        var sumV = 0.0

        var idx = 0
        for _ in 0..<h {
            for _ in 0..<w {
                let v = array[idx].doubleValue
                if v < minV { minV = v }
                if v > maxV { maxV = v }
                sumV += v
                idx += 1
            }
        }

        let span = max(1e-9, maxV - minV)

        // Fill grayscale 8-bit buffer scaled to 0..255
        var out = Data(count: Int(h * bytesPerRow))
        var i = 0
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for _ in 0..<h {
                for _ in 0..<w {
                    let v = array[i].doubleValue
                    let z = max(0.0, min(1.0, (v - minV) / span))
                    p[i] = UInt8(z * 255.0)
                    i += 1
                }
            }
        }

        let meanV = sumV / Double(array.count)
        guard let provider = CGDataProvider(data: out as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bytesPerRow, space: cs, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return (CIImage(cgImage: cg), minV, meanV, maxV)
    }

    /// Compute min/mean/max from a single-channel gray pixel buffer assumed to be 8-bit or normalized 0..1 float.
    private static func statsForGray(pixelBuffer: CVPixelBuffer) -> (min: Double, mean: Double, max: Double)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minV = 1.0, maxV = 0.0, sumV = 0.0
        for y in 0..<h {
            let p = base + y * row
            for x in 0..<w {
                let v = Double(p[x]) / 255.0
                if v < minV { minV = v }
                if v > maxV { maxV = v }
                sumV += v
            }
        }
        let meanV = sumV / Double(w * h)
        return (minV, meanV, maxV)
    }
#endif



    // MARK: - Stub (keeps app functional before model exists)
    private func stubPreview(pixelBuffer _: CVPixelBuffer) {
        // Make a small animated gradient so you can see the overlay plumbing working
        let t = fmod(CFAbsoluteTimeGetCurrent(), 2.0) / 2.0 // 0..1 repeats every 2s
        let w = 128, h = 96
        let bytesPerRow = w
        var data = Data(count: Int(h * bytesPerRow))
        data.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var off = 0
            for y in 0..<h {
                for x in 0..<w {
                    let fx = Double(x) / Double(w - 1)
                    let fy = Double(y) / Double(h - 1)
                    let v = max(0, min(1, fx * 0.8 + fy * 0.2 + t * 0.2 - 0.1))
                    p[off] = UInt8(v * 255.0)
                    off += 1
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bytesPerRow, space: cs, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return }
        let ci = CIImage(cgImage: cg)
        Task { @MainActor [weak self] in
            self?.scalarCI = ci
        }
    }
}

extension ChromaModelManager {
    // MARK: - Developer toggles (explicit setters)
    func setDeveloperMode(_ on: Bool) { developerMode = on }
    func setHeatmapSource(_ src: Source) { heatmapSource = src }
    func setInterpolation(_ mode: Interp) { interpolationMode = mode }
    func setExperimental3DHeatmap(_ on: Bool) { experimental3DHeatmap = on }
    
    func setRotatePreviewUIFlag(_ on: Bool) { setRotatePreviewUI(on) }
    func setUIRotationDegrees(_ deg: Int) { setUIRotationDeg(deg) }
    func setMirrorPreviewFlag(_ on: Bool) { setMirrorPreviewUI(on) }
}
