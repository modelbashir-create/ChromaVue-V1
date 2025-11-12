//
//  HeatmapMesh3DView.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/4/25.
//


import SwiftUI
import SceneKit
import CoreImage
import simd
import UIKit
/// 2.5D experimental heatmap: renders scalarCI as a 3D heightfield with vertex colors.
/// Dev-only, for experimentation.
struct HeatmapMesh3DView: UIViewRepresentable {
    let scalarImage: CIImage

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.scene = SCNScene()
        view.allowsCameraControl = true // Dev only: allow orbit/zoom
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.maximumVerticalAngle = 80
        view.defaultCameraController.minimumVerticalAngle = -80

        // Initial scene setup
        configureScene(view)
        updateGeometry(in: view.scene!, with: scalarImage)

        return view
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }
        updateGeometry(in: scene, with: scalarImage)
    }

    // MARK: - Scene setup

    private func configureScene(_ view: SCNView) {
        guard let scene = view.scene else { return }

        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100.0
        cameraNode.position = SCNVector3(0, 0.4, 1.2)
        cameraNode.eulerAngles = SCNVector3(-0.5, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        // Lights
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .directional
        lightNode.light?.intensity = 900
        lightNode.eulerAngles = SCNVector3(-0.6, 0.8, 0.3)
        scene.rootNode.addChildNode(lightNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300
        ambient.light?.color = UIColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambient)
    }

    // MARK: - Geometry

    private func updateGeometry(in scene: SCNScene, with scalarImage: CIImage) {
        // Downsample to keep mesh small (e.g. 64×64)
        let targetResolution = 64
        guard let field = makeHeightField(from: scalarImage, resolution: targetResolution) else {
            return
        }

        let w = field.width
        let h = field.height
        let values = field.values

        // Generate vertices & colors
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []

        positions.reserveCapacity(w * h)
        colors.reserveCapacity(w * h)

        let scaleX: Float = 1.0
        let scaleZ: Float = 1.0
        let heightScale: Float = 0.3

        for j in 0..<h {
            for i in 0..<w {
                let idx = j * w + i
                let v = values[idx] // 0...1

                // Centered in X/Z
                let x = (Float(i) / Float(max(w - 1, 1)) - 0.5) * scaleX
                let z = (Float(j) / Float(max(h - 1, 1)) - 0.5) * scaleZ
                let y = (v - 0.5) * heightScale

                positions.append(SIMD3<Float>(x, y, z))
                colors.append(colormap(v))
            }
        }

        // Triangles
        var indices: [CInt] = []
        indices.reserveCapacity((w - 1) * (h - 1) * 6)

        for j in 0..<(h - 1) {
            for i in 0..<(w - 1) {
                let i0 = CInt(j * w + i)
                let i1 = CInt(j * w + i + 1)
                let i2 = CInt((j + 1) * w + i)
                let i3 = CInt((j + 1) * w + i + 1)

                // Triangle 1
                indices.append(contentsOf: [i0, i2, i1])
                // Triangle 2
                indices.append(contentsOf: [i1, i2, i3])
            }
        }

        let positionData: Data = positions.withUnsafeBytes { Data($0) }
        let colorData: Data    = colors.withUnsafeBytes { Data($0) }
        let indexData: Data    = indices.withUnsafeBytes { Data($0) }

        let positionSource = SCNGeometrySource(
            data: positionData,
            semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.size
        )

        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.size
        )

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<CInt>.size
        )

        let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [element])
        geometry.firstMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.isDoubleSided = true
            m.diffuse.contents = UIColor.white
            m.metalness.contents = 0.0
            m.roughness.contents = 0.15
            m.transparency = 1.0
            m.blendMode = .alpha
            return m
        }()

        // Replace or add node
        let node: SCNNode
        if let existing = scene.rootNode.childNode(withName: "heatmapMesh", recursively: false) {
            node = existing
        } else {
            node = SCNNode()
            node.name = "heatmapMesh"
            scene.rootNode.addChildNode(node)
        }

        node.geometry = geometry
    }

    // MARK: - Heightfield from CIImage

    private func makeHeightField(from image: CIImage, resolution: Int) -> (width: Int, height: Int, values: [Float])? {
        let ctx = CIContext(options: nil)

        let aspect = image.extent.width / image.extent.height
        let w: Int
        let h: Int
        if aspect >= 1 {
            w = resolution
            h = max(1, Int(Float(resolution) / Float(aspect)))
        } else {
            h = resolution
            w = max(1, Int(Float(resolution) * Float(aspect)))
        }

        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let cg = ctx.createCGImage(image, from: image.extent)?
                .resized(to: rect.size) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = w * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: w * h)

        guard let ctx2 = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        ctx2.interpolationQuality = .high
        ctx2.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let floats = buffer.map { Float($0) / 255.0 }
        return (width: w, height: h, values: floats)
    }

    // Simple blue→red medical-ish colormap
    private func colormap(_ v: Float) -> SIMD4<Float> {
        let t = max(0, min(1, v))
        // Piecewise: blue -> cyan -> green -> yellow -> red
        let r: Float
        let g: Float
        let b: Float

        if t < 0.25 {
            let k = t / 0.25
            r = 0.0
            g = k
            b = 1.0
        } else if t < 0.5 {
            let k = (t - 0.25) / 0.25
            r = 0.0
            g = 1.0
            b = 1.0 - k
        } else if t < 0.75 {
            let k = (t - 0.5) / 0.25
            r = k
            g = 1.0
            b = 0.0
        } else {
            let k = (t - 0.75) / 0.25
            r = 1.0
            g = 1.0 - k
            b = 0.0
        }

        return SIMD4<Float>(r, g, b, 1.0)
    }
}

// MARK: - Small CGImage helper

private extension CGImage {
    func resized(to size: CGSize) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
