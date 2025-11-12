import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// SwiftUI view that renders a full-field scalar (grayscale [0,1]) CIImage as a colorized heatmap overlay.
/// Enhanced with iOS 18+ effects and modern design patterns.
struct HeatmapOverlay: View {
    // Input scalar map (single-channel normalized to [0,1])
    private let scalarImage: CIImage
    /// Interpolation used when drawing the colorized overlay image
    private let interpolation: Image.Interpolation

    /// Access to developer mode + shared heatmap configuration
    @EnvironmentObject var model: ChromaModelManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(fullField scalar: CIImage,
         interpolation: Image.Interpolation = .low) {
        self.scalarImage = scalar
        self.interpolation = interpolation
    }

    private var effectiveOpacity: CGFloat {
        let base = model.heatmapConfig.opacity
        return reduceTransparency ? min(base * 0.7, 0.3) : base
    }

    var body: some View {
        GeometryReader { geo in
            if let img = HeatmapImageRenderer.shared.makeImage(
                fromScalar: scalarImage,
                config: model.heatmapConfig
            ) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(interpolation)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .compositingGroup()
                        .opacity(effectiveOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    if model.developerMode {
                        modernDevBadge
                    }
                }
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
    }
    
    @ViewBuilder
    private var modernDevBadge: some View {
        Text("DEV")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.3), lineWidth: 0.5)
            )
            .foregroundStyle(.yellow)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .padding([.top, .trailing], 8)
            .allowsHitTesting(false)
    }
}

/// Minimal renderer that converts a CIImage into a colorized UIImage.
/// (Applies a blue-white-red gradient color mapping to the grayscale input.)
final class HeatmapImageRenderer {
    static let shared = HeatmapImageRenderer()
    private let context: CIContext = {
        let linearRGB = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: linearRGB,
            .outputColorSpace: sRGB
        ])
    }()
    private init() {}

    func makeImage(fromScalar grayCI: CIImage,
                   config: HeatmapConfiguration) -> UIImage? {
        // Choose gradient based on selected color map
        let gradient: CIImage
        switch config.colorMap {
        case .blueWhiteRed:
            gradient = HeatmapImageRenderer.blueWhiteRedGradientCI()
        case .grayscale:
            gradient = HeatmapImageRenderer.grayscaleGradientCI()
        }

        guard let colorMap = CIFilter(name: "CIColorMap") else { return nil }
        colorMap.setValue(grayCI, forKey: kCIInputImageKey)
        colorMap.setValue(gradient, forKey: "inputGradientImage")
        guard let colored = colorMap.outputImage else { return nil }
        guard let cgImage = context.createCGImage(colored, from: colored.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // Create a 256x1 gradient CIImage from blue (0.0) through near-white (0.5) to red (1.0)
    private static func blueWhiteRedGradientCI() -> CIImage {
        let width = 256, height = 1
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let t = Float(x) / Float(width - 1)
            // Blue (low) to Red (high) with soft neutral near mid
            let low = SIMD3<Float>(0.05, 0.15, 0.95)
            let high = SIMD3<Float>(0.95, 0.15, 0.05)
            var r = low.x + (high.x - low.x) * t
            var g = low.y + (high.y - low.y) * t
            var b = low.z + (high.z - low.z) * t
            // Subtle desaturation near mid to reduce noise
            let mid = abs(t - 0.5) * 2.0
            let desat: Float = 0.12 * (1.0 - mid)
            let gray = (r + g + b) / 3.0
            r = r * (1.0 - desat) + gray * desat
            g = g * (1.0 - desat) + gray * desat
            b = b * (1.0 - desat) + gray * desat
            let i = x * 4
            pixels[i + 0] = UInt8(max(0, min(255, Int(r * 255))))
            pixels[i + 1] = UInt8(max(0, min(255, Int(g * 255))))
            pixels[i + 2] = UInt8(max(0, min(255, Int(b * 255))))
            pixels[i + 3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: cg)
    }

    private static func grayscaleGradientCI() -> CIImage {
        let width = 256, height = 1
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let t = Float(x) / Float(width - 1)
            let v = UInt8(max(0, min(255, Int(t * 255))))
            let i = x * 4
            pixels[i + 0] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
            pixels[i + 3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: cg)
    }
}

#if DEBUG
import SwiftUI

// Build a synthetic scalar field to preview the overlay
private func demoHeatmapCI() -> CIImage {
    let w = 240, h = 180
    let colorSpace = CGColorSpaceCreateDeviceGray()

    var pixels = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let gx = CGFloat(x) / CGFloat(w - 1)
            let gy = CGFloat(y) / CGFloat(h - 1)
            var v = 0.75 * gx + 0.25 * gy
            // add a “defect” island
            let dx = (CGFloat(x) - 0.60 * CGFloat(w))
            let dy = (CGFloat(y) - 0.50 * CGFloat(h))
            let island = exp(-((dx*dx + dy*dy) / (2 * pow(0.12 * CGFloat(w), 2))))
            v = max(0, min(1, v - 0.25 * island))
            pixels[y * w + x] = UInt8((v * 255).rounded())
        }
    }

    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)!
    let cg = CGImage(width: w,
                     height: h,
                     bitsPerComponent: 8,
                     bitsPerPixel: 8,
                     bytesPerRow: w,
                     space: colorSpace,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                     provider: provider,
                     decode: nil,
                     shouldInterpolate: true,
                     intent: .defaultIntent)!
    return CIImage(cgImage: cg)
}

#Preview("Full-field (synthetic)") {
    let ci = demoHeatmapCI()
    HeatmapOverlay(fullField: ci, interpolation: .low)
        .environmentObject(ChromaModelManager.shared)
        .frame(width: 300, height: 220)
        .background(Color.black)
        .padding()
}
#endif
