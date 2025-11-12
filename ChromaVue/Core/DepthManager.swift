//
//  DepthManager.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 10/31/25.
//

//
//  DepthManager.swift
//  ChromaVue
//

import Foundation
import ARKit
import CoreMotion
import Combine

// Coordinate space for exported point clouds
enum CoordinateSpace: Sendable {
    case camera
    case world
}

/// Provides LiDAR scene depth (mean distance), device tilt, and a simple confidence score.
/// Publishes plain values on the main thread to avoid Swift 6 Sendable issues.
final class DepthManager: NSObject, ObservableObject, ARSessionDelegate {

    static let shared = DepthManager()
    private override init() { super.init() }

    // AR session for LiDAR depth
    private let session = ARSession()

    // Motion (for tilt readout)
    private let motion = CMMotionManager()

    // Published values (UI-friendly)
    @Published var meanDistanceMM: Float = 0      // average distance camera→surface
    @Published var tiltDegrees: Float = 0         // pitch magnitude in degrees
    @Published var confidence: Float = 0          // rough 0…1 quality

    /// Side length of the downsampled depth grid (depthSide × depthSide).
    /// This is aligned conceptually with the analysis scalar grid (e.g., 64×64).
    let depthSide: Int = 64

    /// Latest depth grid in meters, downsampled to `depthSide × depthSide`.
    /// This can be used for training (Tier 3) or as an extra CoreML input channel.
    @Published var latestDepthGrid: [Float]? = nil

    // Cache the latest ARFrame for optional point-cloud export
    private var latestFrame: ARFrame?
    @Published var lastPointCount: Int = 0

    // MARK: - Control
    func start() {
        // Configure AR session (enable sceneDepth if supported)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Start device motion for tilt
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(to: .main) { [weak weakSelf = self] dm, _ in
                guard let self = weakSelf, let dm = dm else { return }
                // Use absolute pitch (front–back tilt) in degrees
                let pitchDeg = Float(abs(dm.attitude.pitch) * 180.0 / .pi)
                self.tiltDegrees = pitchDeg
            }
        }
    }

    func stop() {
        session.pause()
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Cache the most recent frame for on-demand 3D export
        self.latestFrame = frame

        guard let sceneDepth = frame.sceneDepth else {
            // No LiDAR depth on this device; publish zeros with low confidence
            DispatchQueue.main.async { [weak weakSelf = self] in
                weakSelf?.meanDistanceMM = 0
                weakSelf?.confidence = 0.1
                weakSelf?.latestDepthGrid = nil
            }
            return
        }

        let depthPB = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPB, .readOnly) }

        let width = CVPixelBufferGetWidth(depthPB)
        let height = CVPixelBufferGetHeight(depthPB)
        let count = width * height

        guard let base = CVPixelBufferGetBaseAddress(depthPB)?
            .assumingMemoryBound(to: Float32.self), count > 0 else {
            DispatchQueue.main.async { [weak weakSelf = self] in
                weakSelf?.meanDistanceMM = 0
                weakSelf?.confidence = 0.1
                weakSelf?.latestDepthGrid = nil
            }
            return
        }

        // Sample about ~10k points for speed
        let step = max(1, count / 10_000)
        var acc = 0.0
        var n = 0
        var i = 0
        while i < count {
            acc += Double(base[i])
            n += 1
            i += step
        }

        let meanMeters = n > 0 ? Float(acc / Double(n)) : 0
        let meanMM = max(0, meanMeters * 1000)

        // Very simple confidence heuristic: prefer 10–60 cm
        let conf: Float
        switch meanMM {
        case 100...600: conf = 0.9
        case 60...800:  conf = 0.7
        case 800...1500: conf = 0.5
        default:        conf = 0.3
        }

        // Build a downsampled depth grid in meters (depthSide × depthSide)
        let side = depthSide
        var depthGrid = [Float](repeating: 0, count: side * side)
        if width > 0 && height > 0 {
            let stepX = max(1, width / side)
            let stepY = max(1, height / side)

            for j in 0..<side {
                let y = min(height - 1, j * stepY + stepY / 2)
                let rowIndex = y * width
                for i in 0..<side {
                    let x = min(width - 1, i * stepX + stepX / 2)
                    let idx = rowIndex + x
                    let z = base[idx] // meters
                    let outIdx = j * side + i
                    if z.isFinite && z > 0 {
                        depthGrid[outIdx] = z
                    } else {
                        depthGrid[outIdx] = 0 // or a sentinel for invalid
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak weakSelf = self] in
            guard let selfRef = weakSelf else { return }
            selfRef.meanDistanceMM = meanMM
            selfRef.confidence = conf
            selfRef.latestDepthGrid = depthGrid
        }
    }

    // MARK: - Point Cloud Export
    /// Exports a decimated point cloud from the latest depth frame.
    /// - Parameters:
    ///   - maxPoints: Target number of points (decimation adapts to stay near this).
    ///   - space: .camera or .world coordinate space.
    ///   - completion: Called on the main thread with the resulting points.
    func exportPointCloud(maxPoints: Int = 20_000,
                          space: CoordinateSpace = .world,
                          completion: @escaping ([SIMD3<Float>]) -> Void) {
        // Access the latest frame on the main thread (ARSession callbacks occur on main by default).
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let frame = self.latestFrame,
                  let sceneDepth = frame.sceneDepth else {
                completion([])
                return
            }
            
            let depthPB = sceneDepth.depthMap
            CVPixelBufferLockBaseAddress(depthPB, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthPB, .readOnly) }
            
            let width = CVPixelBufferGetWidth(depthPB)
            let height = CVPixelBufferGetHeight(depthPB)
            let count = width * height
            
            guard let base = CVPixelBufferGetBaseAddress(depthPB)?.assumingMemoryBound(to: Float32.self),
                  count > 0 else {
                completion([])
                return
            }
            
            // Determine decimation step to approximate maxPoints
            let step = max(1, count / max(1, maxPoints))
            
            // Camera intrinsics
            let intr = frame.camera.intrinsics
            let fx = intr.columns.0.x
            let fy = intr.columns.1.y
            let cx = intr.columns.2.x
            let cy = intr.columns.2.y
            
            // Transform for world coordinates if requested
            let camToWorld = frame.camera.transform
            
            // Build points off the main thread
            DispatchQueue.global(qos: .userInitiated).async {
                var points: [SIMD3<Float>] = []
                points.reserveCapacity(min(count / step, maxPoints))
                
                // Iterate in raster order with decimation
                var y = 0
                while y < height {
                    var x = 0
                    while x < width {
                        let i = y * width + x
                        let z = base[i] // meters from camera
                        if z.isFinite && z > 0 {
                            // Unproject pixel (x,y,z) to camera-space XYZ using pinhole model
                            let X = (Float(x) - cx) * z / fx
                            let Y = (Float(y) - cy) * z / fy
                            let camPoint = SIMD3<Float>(X, Y, z)
                            
                            if case .world = space {
                                // Convert to world space (apply 4x4 transform)
                                let v4 = SIMD4<Float>(camPoint.x, camPoint.y, camPoint.z, 1.0)
                                let w4 = camToWorld * v4
                                points.append(SIMD3<Float>(w4.x, w4.y, w4.z))
                            } else {
                                points.append(camPoint)
                            }
                        }
                        x += step
                    }
                    y += step
                }
                
                // Publish the count and return points on main
                DispatchQueue.main.async { [weak weakSelf = self] in
                    weakSelf?.lastPointCount = points.count
                    completion(points)
                }
            }
        }
    }
}
