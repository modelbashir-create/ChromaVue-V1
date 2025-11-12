//
//  pipeline.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/4/25.
//

//
//  AnalysisManager.swift
//  ChromaVue
//
//  Full-field oxygenation *preview* index in real time.
//  - Flash OFF frames:  log10(R/G)
//  - Flash ON/OFF pair: log10(ΔR/ΔG) where Δ = ON − OFF (within a short time window)
//  Publishes:
//    • scalar CIImage (grayscale) via ChromaModelManager.shared.updateAnalyticScalarGrid(_:side:lo:hi:)
//    • meanR, meanG, logRG for the developer Live Analysis HUD
//    • scalarMean, scalarStd, and latestScalarGrid for training export
//

import Foundation
import CoreVideo
import CoreImage
import CoreGraphics
import Combine
import simd
#if canImport(MetalPerformanceShadersGraph)
import MetalPerformanceShadersGraph
#endif

// MARK: - Value types for actor pipeline

struct AnalysisInputFrame: Sendable {
    let timestampMS: Int64
    /// true when the camera flash (LED) is ON for this frame
    let flashOn: Bool
    let scalarSize: Int
    let useGPUAcceleration: Bool
    let R: [Float]
    let G: [Float]
    let B: [Float]
    let meanR: Double   // 0..255
    let meanG: Double
    let meanB: Double
}

struct AnalysisOutputFrame: Sendable {
    // HUD values
    let fps: Double
    let meanR: Double
    let meanG: Double
    let logRG: Double

    // Tri-band intensities & deltas
    let I555: Double
    let I590: Double
    let I640: Double
    let dI555: Double?
    let dI590: Double?
    let dI640: Double?
    let log_555_590: Double?
    let log_640_590: Double?
    let log_555_640: Double?

    // Scalar preview map (clamped to display range)
    let scalar: [Float]

    // Pairing status for this frame (useful for Training Mode export)
    let pairStatus: PairStatus
}

enum PairStatus: Sendable {
    /// Not part of a valid OFF/ON pair (fallback scalar: log10(R/G))
    case none
    /// Flash OFF frame that refreshed the OFF baseline used for the next pair
    case baselineOff
    /// Flash ON frame that consumed a recent OFF baseline to compute ΔR/ΔG
    case pairedOn
}

// MARK: - Actor with all heavy math & state

actor AnalysisEngine {
    // FPS EMA
    private var lastTimestampMS: Int64?
    private let fpsAlpha: Double = 0.25
    private var fpsEMA: Double?

    // Alternation state for full-field scalar maps
    private var lastOffR: [Float]?
    private var lastOffG: [Float]?
    private var lastOffTS: Int64 = 0
    private let pairWindowMS: Int64 = 120

    // Tri-band pairing state (means)
    private var lastOffBandsMean: SIMD3<Float>?

    func process(input: AnalysisInputFrame) async -> AnalysisOutputFrame {
        let ts = input.timestampMS
        let flashOn = input.flashOn
        let scalarSize = input.scalarSize
        let useGPU = input.useGPUAcceleration
        let count = scalarSize * scalarSize
        let R = input.R
        let G = input.G
        let eps: Float = 1e-6

        var pairStatus: PairStatus = .none

        // --- FPS (EMA) ---
        var fpsOut: Double = fpsEMA ?? 0
        if let last = lastTimestampMS, ts > last {
            let inst = 1000.0 / Double(ts - last)
            let ema = fpsAlpha * inst + (1.0 - fpsAlpha) * (fpsEMA ?? inst)
            fpsEMA = ema
            fpsOut = ema
        }
        lastTimestampMS = ts

        // --- Developer HUD means + logRG ---
        let meanR = input.meanR
        let meanG = input.meanG
        let logRG = log10(
            max(1e-6, meanR) /
            max(1e-6, meanG)
        )

        // --- Scalar log-map (Δ pair or OFF-style log(R/G)) ---
        var scalar = [Float](repeating: 0, count: count)

        if flashOn, let offR = lastOffR, let offG = lastOffG,
           (ts - lastOffTS) <= pairWindowMS {
            // Valid OFF/ON pair → compute ΔR/ΔG scalar
            if useGPU {
                let gpu: [Float]? = await MainActor.run {
                    MPSGraphHelper.deltaAndLogRatio(
                        offR: offR, offG: offG,
                        onR: R, onG: G,
                        eps: eps,
                        clampLo: -0.30,
                        clampHi: 0.30
                    )
                }
                if let gpu {
                    // GPU path
                    scalar = gpu
                } else {
                    // CPU path (GPU helper failed)
                    for i in 0..<count {
                        let dR = max(eps, R[i] - offR[i])
                        let dG = max(eps, G[i] - offG[i])
                        scalar[i] = log10(dR / dG)
                    }
                }
            } else {
                // CPU path (GPU disabled)
                for i in 0..<count {
                    let dR = max(eps, R[i] - offR[i])
                    let dG = max(eps, G[i] - offG[i])
                    scalar[i] = log10(dR / dG)
                }
            }
            // consume pair
            lastOffR = nil
            lastOffG = nil
            lastOffTS = 0
            pairStatus = .pairedOn
        } else {
            // Fallback: single-frame log(R/G)
            for i in 0..<count {
                scalar[i] = log10(max(eps, R[i]) / max(eps, G[i]))
            }
            if !flashOn {
                // Refresh OFF baseline on flash OFF frames
                lastOffR = R
                lastOffG = G
                lastOffTS = ts
                pairStatus = .baselineOff
            }
        }

        // --- Tri-band mapping from RGB means + Δ/log ratios ---
        let rμ = Float(input.meanR) / 255.0
        let gμ = Float(input.meanG) / 255.0
        let bμ = Float(input.meanB) / 255.0
        let bandsOn = mapRGBtoBands(r: rμ, g: gμ, b: bμ)

        let I555 = Double(bandsOn.x)
        let I590 = Double(bandsOn.y)
        let I640 = Double(bandsOn.z)

        var dI555: Double? = nil
        var dI590: Double? = nil
        var dI640: Double? = nil
        var log_555_590: Double? = nil
        var log_640_590: Double? = nil
        var log_555_640: Double? = nil

        if flashOn,
           (ts - lastOffTS) <= pairWindowMS,
           let offBands = lastOffBandsMean {
            let d = bandsOn - offBands
            dI555 = Double(d.x)
            dI590 = Double(d.y)
            dI640 = Double(d.z)
            log_555_590 = Double(log10(max(eps, bandsOn.x) / max(eps, bandsOn.y)))
            log_640_590 = Double(log10(max(eps, bandsOn.z) / max(eps, bandsOn.y)))
            log_555_640 = Double(log10(max(eps, bandsOn.x) / max(eps, bandsOn.z)))
            lastOffBandsMean = nil
        } else if !flashOn {
            lastOffBandsMean = bandsOn
        }

        // Clamp scalar for display range
        let lo: Float = -0.30, hi: Float = 0.30
        for i in 0..<count {
            let v = scalar[i]
            scalar[i] = min(hi, max(lo, v))
        }

        return AnalysisOutputFrame(
            fps: fpsOut,
            meanR: meanR,
            meanG: meanG,
            logRG: logRG,
            I555: I555,
            I590: I590,
            I640: I640,
            dI555: dI555,
            dI590: dI590,
            dI640: dI640,
            log_555_590: log_555_590,
            log_640_590: log_640_590,
            log_555_640: log_555_640,
            scalar: scalar,
            pairStatus: pairStatus
        )
    }

    // Same mapping you had before, moved into the actor
    private func mapRGBtoBands(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        let M = float3x3([
            SIMD3(0.06, 0.88, 0.06),  // → 555
            SIMD3(0.28, 0.66, 0.06),  // → 590
            SIMD3(0.87, 0.11, 0.02)   // → 640
        ])
        let v = SIMD3(r, g, b)
        let out = M * v
        let eps: Float = 1e-6
        return SIMD3(max(eps, out.x), max(eps, out.y), max(eps, out.z))
    }
}

// MARK: - Main-actor view model

@MainActor
final class AnalysisManager: ObservableObject {
    static let shared = AnalysisManager(engine: AnalysisEngine())

    // Inject the actor (can be made injectable for tests)
    private let engine: AnalysisEngine

    private init(engine: AnalysisEngine) {
        self.engine = engine
    }

    // Developer HUD stats
    @Published var meanR: CGFloat = 0
    @Published var meanG: CGFloat = 0
    @Published var logRG: CGFloat = 0

    // FPS (EMA) for developer HUD
    @Published var fps: Double = 0

    // Dev toggle: prefer GPU (MPSGraph) for scalar math when available.
    @Published var useGPUAcceleration: Bool = true

    // Tri-band instantaneous intensities (proxy 555/590/640 from mean RGB)
    @Published var I555: Double = 0
    @Published var I590: Double = 0
    @Published var I640: Double = 0

    // Δ pairs (ON − OFF) and band log-ratios (computed on valid ON/OFF pairs)
    @Published var dI555: Double? = nil
    @Published var dI590: Double? = nil
    @Published var dI640: Double? = nil
    @Published var log_555_590: Double? = nil
    @Published var log_640_590: Double? = nil
    @Published var log_555_640: Double? = nil

    // Tier 2: scalar summary statistics for export
    @Published var scalarMean: Double? = nil
    @Published var scalarStd: Double? = nil

    // Tier 3: latest scalar field grid (as used for preview/export)
    /// Latest scalar grid in log-domain (size scalarSize × scalarSize),
    /// used for Tier 3 training export.
    private(set) var latestScalarGrid: [Float]? = nil

    /// Latest downsampled RGB grids (size scalarSize × scalarSize, values in [0,1]).
    /// These are intended for Tier 3 training export and as additional CoreML input channels.
    private(set) var latestRGrid: [Float]? = nil
    private(set) var latestGGrid: [Float]? = nil
    private(set) var latestBGrid: [Float]? = nil

    // Output size (square) of the scalar preview map
    private let scalarSize = 64

    // MARK: - Public API (called from CameraManager)

    func process(pixelBuffer pb: CVPixelBuffer,
                 flashOn: Bool,
                 timestampMS ts: Int64) {

        let scalarSize = self.scalarSize
        let useGPU = self.useGPUAcceleration

        // Sample R/G/B grids and means on the main actor.
        let (R, G, B, rMean, gMean, bMean) = sampleRGBGrid(from: pb, outSize: scalarSize)

        // Store latest RGB grids for training/CoreML use.
        self.latestRGrid = R
        self.latestGGrid = G
        self.latestBGrid = B

        let input = AnalysisInputFrame(
            timestampMS: ts,
            flashOn: flashOn,
            scalarSize: scalarSize,
            useGPUAcceleration: useGPU,
            R: R,
            G: G,
            B: B,
            meanR: rMean,
            meanG: gMean,
            meanB: bMean
        )

        // Hand off heavy math to the AnalysisEngine actor.
        Task { [weak self] in
            guard let self else { return }
            let output = await self.engine.process(input: input)
            self.apply(output: output)
        }
    }

    /// Legacy entry kept for compatibility; calls the new API with flash OFF and no timestamp.
    func process(pixelBuffer pb: CVPixelBuffer) {
        process(pixelBuffer: pb, flashOn: false, timestampMS: 0)
    }

    // MARK: - Apply actor output on the main actor

    private func apply(output: AnalysisOutputFrame) {
        // HUD
        fps   = output.fps
        meanR = CGFloat(output.meanR)
        meanG = CGFloat(output.meanG)
        logRG = CGFloat(output.logRG)

        // Tri-band + Δ
        I555 = output.I555
        I590 = output.I590
        I640 = output.I640
        dI555 = output.dI555
        dI590 = output.dI590
        dI640 = output.dI640
        log_555_590 = output.log_555_590
        log_640_590 = output.log_640_590
        log_555_640 = output.log_555_640

        // Tier 2: scalar summary (mean/std)
        if !output.scalar.isEmpty {
            let n = Double(output.scalar.count)
            let sum = output.scalar.reduce(0.0) { $0 + Double($1) }
            let mean = sum / n
            let varianceSum = output.scalar.reduce(0.0) { acc, v in
                let dv = Double(v) - mean
                return acc + dv * dv
            }
            let std = sqrt(varianceSum / max(1.0, n - 1.0))
            scalarMean = mean
            scalarStd = std
        } else {
            scalarMean = nil
            scalarStd = nil
        }

        // Tier 3: retain latest scalar grid for export
        latestScalarGrid = output.scalar

        // Scalar CIImage for HUD (clamped to display range) is built by ChromaModelManager
        let lo: Float = -0.30, hi: Float = 0.30
        ChromaModelManager.shared.updateAnalyticScalarGrid(
            output.scalar,
            side: scalarSize,
            lo: lo,
            hi: hi
        )
    }
}

// MARK: - Helpers

/// Variant that samples B as well; returns R,G,B grids in [0,1] and mean channel values in 0..255.
private func sampleRGBGrid(from pb: CVPixelBuffer, outSize n: Int)
-> ([Float],[Float],[Float], Double, Double, Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
        return (
            [Float](repeating: 0, count: n*n),
            [Float](repeating: 0, count: n*n),
            [Float](repeating: 0, count: n*n),
            0, 0, 0
        )
    }

    let stepX = max(1, w / n)
    let stepY = max(1, h / n)

    var R = [Float](repeating: 0, count: n*n)
    var G = [Float](repeating: 0, count: n*n)
    var B = [Float](repeating: 0, count: n*n)

    var rSum = 0.0, gSum = 0.0, bSum = 0.0, count = 0.0

    for j in 0..<n {
        let y = min(h - 1, j * stepY + stepY/2)
        let rowPtr = base + y * rowBytes
        for i in 0..<n {
            let x = min(w - 1, i * stepX + stepX/2)
            let o = x << 2 // BGRA
            let b = rowPtr[o + 0]
            let g = rowPtr[o + 1]
            let r = rowPtr[o + 2]
            let idx = j * n + i
            let rf = Float(r) / 255.0
            let gf = Float(g) / 255.0
            let bf = Float(b) / 255.0
            R[idx] = rf
            G[idx] = gf
            B[idx] = bf
            rSum += Double(r)
            gSum += Double(g)
            bSum += Double(b)
            count += 1.0
        }
    }

    let rMean = count > 0 ? rSum / count : 0.0
    let gMean = count > 0 ? gSum / count : 0.0
    let bMean = count > 0 ? bSum / count : 0.0
    return (R, G, B, rMean, gMean, bMean)
}
