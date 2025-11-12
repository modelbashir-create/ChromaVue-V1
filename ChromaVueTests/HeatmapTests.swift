//
//  HeatmapTests.swift
//  ChromaVueTests
//
//  Created by Mohamed Elbashir on 11/1/25.
//

import Testing
@testable import ChromaVue

@Suite("Heatmap Rendering Tests")
struct HeatmapTests {

    @Test("Blue-White-Red colormap stops")
    func blueWhiteRedStops() async throws {
        let blue = HeatmapRenderer.blueWhiteRed(0.0)
        #expect(abs(blue.r - 0.0) < 0.001)
        #expect(abs(blue.g - 0.0) < 0.001)
        #expect(abs(blue.b - 1.0) < 0.001)

        let white = HeatmapRenderer.blueWhiteRed(0.5)
        #expect(abs(white.r - 1.0) < 0.001)
        #expect(abs(white.g - 1.0) < 0.001)
        #expect(abs(white.b - 1.0) < 0.001)

        let red = HeatmapRenderer.blueWhiteRed(1.0)
        #expect(abs(red.r - 1.0) < 0.001)
        #expect(abs(red.g - 0.0) < 0.001)
        #expect(abs(red.b - 0.0) < 0.001)
    }

    @Test("Gradient builds successfully")
    func gradientBuildsSuccessfully() async throws {
        let gradient = HeatmapRenderer.makeBlueWhiteRedGradientCI()
        #expect(gradient.extent.width > 0, "Gradient should have positive width")
        #expect(gradient.extent.height > 0, "Gradient should have positive height")
    }
    
    @Test("Viridis gradient builds successfully")
    func viridisGradientBuildsSuccessfully() async throws {
        let gradient = HeatmapRenderer.makeViridisGradientCI()
        #expect(gradient.extent.width > 0, "Viridis gradient should have positive width")
        #expect(gradient.extent.height > 0, "Viridis gradient should have positive height")
    }
}
