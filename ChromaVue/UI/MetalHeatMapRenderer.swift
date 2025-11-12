import Metal
import MetalKit
import CoreImage
import SwiftUI
import simd
import Combine

/// High-performance Metal-based heat map renderer for real-time medical visualization
final class MetalHeatMapRenderer: NSObject, ObservableObject {
    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer
    private var uniformBuffer: MTLBuffer
    
    @Published var currentTexture: MTLTexture?
    @Published var isProcessing = false
    
    private struct Uniforms {
        var time: Float
        var resolution: simd_float2
        var colorMapMode: Int32
        var brightness: Float
        var contrast: Float
        var gamma: Float
        var minValue: Float
        var maxValue: Float
        var contourLevels: Int32
        var showContours: Int32
        var animation: Float
    }
    
    private struct Vertex {
        var position: simd_float2
        var texCoord: simd_float2
    }
    
    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Create vertex data for full-screen quad
        let vertices = [
            Vertex(position: simd_float2(-1, -1), texCoord: simd_float2(0, 1)),
            Vertex(position: simd_float2( 1, -1), texCoord: simd_float2(1, 1)),
            Vertex(position: simd_float2(-1,  1), texCoord: simd_float2(0, 0)),
            Vertex(position: simd_float2( 1,  1), texCoord: simd_float2(1, 0))
        ]
        
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride,
            options: []
        ), let uniformBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.size,
            options: []
        ) else {
            fatalError("Failed to create Metal buffers")
        }
        
        self.vertexBuffer = vertexBuffer
        self.uniformBuffer = uniformBuffer
        
        // Load shaders and create pipeline states
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "heatmap_vertex"),
              let fragmentFunction = library.makeFunction(name: "heatmap_fragment") else {
            fatalError("Failed to load Metal shader functions. Make sure HeatMapShaders.metal is included in your project.")
        }
        
        // Create render pipeline
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.fragmentFunction = fragmentFunction
        renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderDescriptor.colorAttachments[0].isBlendingEnabled = true
        renderDescriptor.colorAttachments[0].rgbBlendOperation = .add
        renderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        renderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.renderPipelineState = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            fatalError("Failed to create Metal pipeline states: \(error)")
        }
        
        super.init()
    }
    
    func renderHeatMap(from scalarImage: CIImage,
                      colorMapMode: Int = 0,
                      brightness: Float = 0.0,
                      contrast: Float = 1.0,
                      gamma: Float = 1.0,
                      showContours: Bool = false,
                      contourLevels: Int = 8,
                      animationTime: Float = 0.0) -> MTLTexture? {
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        
        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = true
        }
        
        // Convert CIImage to Metal texture
        guard let inputTexture = createTexture(from: scalarImage) else { 
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return nil 
        }
        
        // Create output texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scalarImage.extent.width),
            height: Int(scalarImage.extent.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        
        guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return nil
        }
        
        // Update uniforms
        let uniforms = Uniforms(
            time: animationTime,
            resolution: simd_float2(Float(scalarImage.extent.width), Float(scalarImage.extent.height)),
            colorMapMode: Int32(colorMapMode),
            brightness: brightness,
            contrast: contrast,
            gamma: gamma,
            minValue: 0.0,
            maxValue: 1.0,
            contourLevels: Int32(contourLevels),
            showContours: showContours ? 1 : 0,
            animation: animationTime
        )
        
        uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1).pointee = uniforms
        
        // Single render pass (no need for separate compute pass)
        let renderDescriptor = MTLRenderPassDescriptor()
        renderDescriptor.colorAttachments[0].texture = outputTexture
        renderDescriptor.colorAttachments[0].loadAction = .clear
        renderDescriptor.colorAttachments[0].storeAction = .store
        renderDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return nil
        }
        
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(inputTexture, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.currentTexture = outputTexture
            }
        }
        
        commandBuffer.commit()
        return outputTexture
    }
    
    private func createTexture(from image: CIImage) -> MTLTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(image.extent.width),
            height: Int(image.extent.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        // Convert CIImage to texture data
        let context = CIContext(mtlDevice: device)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        context.render(image,
                      to: texture,
                      commandBuffer: nil,
                      bounds: image.extent,
                      colorSpace: colorSpace)
        
        return texture
    }
}

/// SwiftUI wrapper for Metal heat map renderer
struct MetalHeatMapView: UIViewRepresentable {
    let scalarImage: CIImage
    let colorMapMode: Int
    let brightness: Float
    let contrast: Float
    let gamma: Float
    let showContours: Bool
    let contourLevels: Int
    
    @StateObject private var renderer = MetalHeatMapRenderer()
    @State private var animationTime: Float = 0.0
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.drawableSize = CGSize(width: scalarImage.extent.width, height: scalarImage.extent.height)
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.updateImage(scalarImage)
        context.coordinator.updateRenderingParameters(
            colorMapMode: colorMapMode,
            brightness: brightness,
            contrast: contrast,
            gamma: gamma,
            showContours: showContours,
            contourLevels: contourLevels
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        let parent: MetalHeatMapView
        private var currentScalarImage: CIImage?
        private var needsUpdate = false
        
        init(_ parent: MetalHeatMapView) {
            self.parent = parent
        }
        
        func updateImage(_ image: CIImage) {
            currentScalarImage = image
            needsUpdate = true
        }
        
        func updateRenderingParameters(colorMapMode: Int, brightness: Float, contrast: Float, gamma: Float, showContours: Bool, contourLevels: Int) {
            needsUpdate = true
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize if needed
            needsUpdate = true
        }
        
        func draw(in view: MTKView) {
            guard needsUpdate,
                  let scalarImage = currentScalarImage,
                  let drawable = view.currentDrawable else { return }
            
            needsUpdate = false
            
            // Update animation time
            parent.animationTime += 1.0/60.0 // Assume 60 FPS
            
            if let outputTexture = parent.renderer.renderHeatMap(
                from: scalarImage,
                colorMapMode: parent.colorMapMode,
                brightness: parent.brightness,
                contrast: parent.contrast,
                gamma: parent.gamma,
                showContours: parent.showContours,
                contourLevels: parent.contourLevels,
                animationTime: parent.animationTime
            ) {
                // Copy output texture to drawable
                guard let commandBuffer = view.device?.makeCommandQueue()?.makeCommandBuffer(),
                      let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
                
                blitEncoder.copy(from: outputTexture,
                               sourceSlice: 0,
                               sourceLevel: 0,
                               sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                               sourceSize: MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
                               to: drawable.texture,
                               destinationSlice: 0,
                               destinationLevel: 0,
                               destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                
                blitEncoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
}
