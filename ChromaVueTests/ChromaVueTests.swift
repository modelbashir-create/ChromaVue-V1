//
//  ChromaVueTests.swift
//  ChromaVueTests
//
//  Created by Mohamed Elbashir on 10/31/25.
//

import Testing
@testable import ChromaVue

@Suite("ChromaVue Core Tests")
struct ChromaVueTests {
    
    @Test("Camera Manager Initialization")
    func cameraManagerInitialization() async throws {
        let cameraManager = ChromaCameraManager.shared
        #expect(cameraManager.isSessionRunning == false)
        #expect(cameraManager.isTorchOn == false)
    }
    
    @Test("Data Export Manager Session Creation")
    func dataExportManagerSessionCreation() async throws {
        let exportManager = DataExportManager.shared
        exportManager.isEnabledDev = true
        
        exportManager.beginNewSession()
        
        #expect(exportManager.sessionFolder != nil)
        #expect(!exportManager.sessionID.isEmpty)
        
        exportManager.endSession()
        #expect(exportManager.sessionFolder == nil)
    }
    
    @Test("Metal Heat Map Renderer Initialization")
    func metalHeatMapRendererInitialization() async throws {
        // Only test on devices that support Metal
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available on this device")
        }
        
        let renderer = MetalHeatMapRenderer()
        #expect(renderer.isProcessing == false)
    }
}

// MARK: - Performance Tests
@Suite("Performance Tests")
struct PerformanceTests {
    
    @Test("Depth Processing Performance", .timeLimit(.seconds(1)))
    func depthProcessingPerformance() async throws {
        let depthManager = DepthManager.shared
        // Add actual performance test logic here
        #expect(depthManager.meanDistanceMM >= 0)
    }
}
