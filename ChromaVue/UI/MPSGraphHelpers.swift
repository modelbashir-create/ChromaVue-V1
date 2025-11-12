import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(MetalPerformanceShadersGraph)
import MetalPerformanceShadersGraph
import Metal
#endif
import Combine

public struct MPSGraphHelper {
    public static var isAvailable: Bool {
        #if canImport(MetalPerformanceShadersGraph)
        return true
        #else
        return false
        #endif
    }

    /// Compute log10( max(eps, onR-offR) / max(eps, onG-offG) ) clamped to [clampLo, clampHi].
    /// If MPSGraph is available, this runs on GPU; otherwise, it falls back to a CPU implementation.
    public static func deltaAndLogRatio(
        offR: [Float],
        offG: [Float],
        onR: [Float],
        onG: [Float],
        eps: Float,
        clampLo: Float,
        clampHi: Float,
        preferGPU: Bool = true
    ) -> [Float]? {
        guard preferGPU else { return nil }
        let n = offR.count
        guard n == offG.count, n == onR.count, n == onG.count, n > 0 else { return nil }

        #if canImport(MetalPerformanceShadersGraph)
        // --- MPSGraph path ---
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else { return nil }
        let device = MPSGraphDevice(mtlDevice: mtlDevice)
        let graph = MPSGraph()
        let shape: [NSNumber] = [NSNumber(value: n)]

        // Placeholders
        let offRT = graph.placeholder(shape: shape, dataType: .float32, name: "offR")
        let offGT = graph.placeholder(shape: shape, dataType: .float32, name: "offG")
        let onRT  = graph.placeholder(shape: shape, dataType: .float32, name: "onR")
        let onGT  = graph.placeholder(shape: shape, dataType: .float32, name: "onG")

        // Scalars
        let epsT = graph.constant(Double(eps), shape: [], dataType: .float32)
        let loT  = graph.constant(Double(clampLo), shape: [], dataType: .float32)
        let hiT  = graph.constant(Double(clampHi), shape: [], dataType: .float32)
        let ln10 = graph.constant(Double(log(10.0)), shape: [], dataType: .float32)

        // dR = max(eps, onR - offR); dG = max(eps, onG - offG)
        let subR = graph.subtraction(onRT, offRT, name: "subR")
        let subG = graph.subtraction(onGT, offGT, name: "subG")
        let dR   = graph.maximum(subR, epsT, name: "dR")
        let dG   = graph.maximum(subG, epsT, name: "dG")

        // ratio = dR / dG
        let ratio = graph.division(dR, dG, name: "ratio")

        // log10(ratio) = ln(ratio) / ln(10)
        let lnRatio = graph.logarithm(with: ratio, name: "lnRatio")
        let log10T  = graph.division(lnRatio, ln10, name: "log10T")

        // clamp to [lo, hi]
        let clamped = graph.clamp(log10T, min: loT, max: hiT, name: "clamped")

        // Prepare feeds
        func tensorData(_ a: [Float]) -> MPSGraphTensorData? {
            let data = a.withUnsafeBytes { Data($0) }
            // Use the correct initializer for MPSGraphTensorData
            return MPSGraphTensorData(device: device, data: data, shape: shape, dataType: .float32)
        }

        guard
            let offRData = tensorData(offR),
            let offGData = tensorData(offG),
            let onRData  = tensorData(onR),
            let onGData  = tensorData(onG)
        else { return nil }

        let feeds: [MPSGraphTensor : MPSGraphTensorData] = [
            offRT : offRData,
            offGT : offGData,
            onRT  : onRData,
            onGT  : onGData
        ]

        // Create command queue from device
        guard let commandQueue = mtlDevice.makeCommandQueue() else { return nil }
        
        let results = graph.run(with: commandQueue, feeds: feeds, targetTensors: [clamped], targetOperations: nil)
        guard let resultData = results[clamped] else {
            return nil
        }

        // Read result - MPSGraphTensorData provides access through mpsndarray
        let count = n
        var out = [Float](repeating: 0, count: count)
        
        // Get the MPSNDArray from the tensor data
        let ndArray = resultData.mpsndarray()
        
        // Read bytes from the NDArray
        ndArray.readBytes(&out, strideBytes: nil)
        return out
        #else
        // --- CPU fallback ---
        var out = [Float](repeating: 0, count: n)
        let lo = clampLo
        let hi = clampHi
        let invLn10 = 1.0 as Float / logf(10)
        for i in 0..<n {
            let dR = max(onR[i] - offR[i], eps)
            let dG = max(onG[i] - offG[i], eps)
            let ratio = dR / dG
            var v = logf(ratio) * invLn10
            if v < lo { v = lo } else if v > hi { v = hi }
            out[i] = v
        }
        return out
        #endif
    }

    /// Compute log10( max(eps, R) / max(eps, G) ) clamped to [clampLo, clampHi].
    /// If MPSGraph is available, this runs on GPU; otherwise, it falls back to a CPU implementation.
    public static func logRatioRG(
        R: [Float],
        G: [Float],
        eps: Float,
        clampLo: Float,
        clampHi: Float,
        preferGPU: Bool = true
    ) -> [Float]? {
        guard preferGPU else { return nil }
        let n = R.count
        guard n == G.count, n > 0 else { return nil }

        #if canImport(MetalPerformanceShadersGraph)
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else { return nil }
        let device = MPSGraphDevice(mtlDevice: mtlDevice)
        let graph = MPSGraph()
        let shape: [NSNumber] = [NSNumber(value: n)]

        let RT = graph.placeholder(shape: shape, dataType: .float32, name: "R")
        let GT = graph.placeholder(shape: shape, dataType: .float32, name: "G")

        let epsT = graph.constant(Double(eps), shape: [], dataType: .float32)
        let loT  = graph.constant(Double(clampLo), shape: [], dataType: .float32)
        let hiT  = graph.constant(Double(clampHi), shape: [], dataType: .float32)
        let ln10 = graph.constant(Double(log(10.0)), shape: [], dataType: .float32)

        let maxR = graph.maximum(RT, epsT, name: "maxR")
        let maxG = graph.maximum(GT, epsT, name: "maxG")

        let ratio = graph.division(maxR, maxG, name: "ratio")
        let lnRatio = graph.logarithm(with: ratio, name: "lnRatio")
        let log10T  = graph.division(lnRatio, ln10, name: "log10T")

        let clamped = graph.clamp(log10T, min: loT, max: hiT, name: "clamped")

        func tensorData(_ a: [Float]) -> MPSGraphTensorData? {
            let data = a.withUnsafeBytes { Data($0) }
            return MPSGraphTensorData(device: device, data: data, shape: shape, dataType: .float32)
        }

        guard let RData = tensorData(R), let GData = tensorData(G) else { return nil }

        let feeds: [MPSGraphTensor : MPSGraphTensorData] = [
            RT : RData,
            GT : GData
        ]

        guard let commandQueue = mtlDevice.makeCommandQueue() else { return nil }
        let results = graph.run(with: commandQueue, feeds: feeds, targetTensors: [clamped], targetOperations: nil)
        guard let resultData = results[clamped] else { return nil }

        var out = [Float](repeating: 0, count: n)
        let ndArray = resultData.mpsndarray()
        ndArray.readBytes(&out, strideBytes: nil)
        return out
        #else
        var out = [Float](repeating: 0, count: n)
        let lo = clampLo
        let hi = clampHi
        let invLn10 = 1.0 as Float / logf(10)
        for i in 0..<n {
            let val = logf(max(eps, R[i]) / max(eps, G[i])) * invLn10
            out[i] = max(lo, min(hi, val))
        }
        return out
        #endif
    }
}
