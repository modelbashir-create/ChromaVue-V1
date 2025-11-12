//
//  CameraPreview.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 10/31/25.
//

import SwiftUI
import AVFoundation

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer.
/// Enhanced with iOS 18+ Liquid Glass effects and modern design patterns.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// When true, enables UI rotation via ChromaCameraManager's rotation system.
    /// Analysis/export buffers remain portrait (90°) for data consistency.
    @Binding var rotateWithDevice: Bool
    
    // iOS 18+ Environment detection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Convenience init: keeps existing call sites working without changes.
    init(session: AVCaptureSession, rotateWithDevice: Binding<Bool> = .constant(false)) {
        self.session = session
        self._rotateWithDevice = rotateWithDevice
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        // Prefer wide color when available
        if #available(iOS 16.0, *) {
            uiViewPerform { v in
                v.videoPreviewLayer.contentsScale = v.contentScaleFactor
                v.videoPreviewLayer.isGeometryFlipped = false
                v.videoPreviewLayer.masksToBounds = true
                v.videoPreviewLayer.isOpaque = true
            }
        } else {
            v.videoPreviewLayer.masksToBounds = true
            v.videoPreviewLayer.isOpaque = true
        }
        
        // Subtle edge fade mask for premium feel (does not affect buffers)
        let maskLayer = CAGradientLayer()
        maskLayer.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        maskLayer.locations = [0.0, 0.92, 1.0]
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        maskLayer.frame = v.bounds
        v.layer.mask = maskLayer
        
        // Initialize rotation state with ChromaCameraManager
        // Note: ChromaCameraManager.attachPreviewLayerForUIRotation is @MainActor
        Task(priority: .userInitiated) {
            await MainActor.run {
                if rotateWithDevice {
                    ChromaCameraManager.shared.attachPreviewLayerForUIRotation(v.videoPreviewLayer)
                } else {
                    ChromaCameraManager.shared.detachPreviewLayerFromUIRotation(v.videoPreviewLayer)
                    // When rotation is disabled, reset to portrait orientation (90°)
                    if let connection = v.videoPreviewLayer.connection,
                       connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                    v.videoPreviewLayer.videoGravity = .resizeAspectFill
                }
            }
        }
        
        // Accessibility: hide from accessibility elements
        v.isAccessibilityElement = false
        
        func uiViewPerform(_ block: (PreviewView) -> Void) { block(v) }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let maskLayer = uiView.layer.mask as? CAGradientLayer {
            maskLayer.frame = uiView.bounds
        }
        
        uiView.videoPreviewLayer.contentsScale = uiView.contentScaleFactor
        
        // Update rotation state in ChromaCameraManager when binding changes
        Task(priority: .userInitiated) {
            await MainActor.run {
                if rotateWithDevice {
                    ChromaCameraManager.shared.attachPreviewLayerForUIRotation(uiView.videoPreviewLayer)
                } else {
                    ChromaCameraManager.shared.detachPreviewLayerFromUIRotation(uiView.videoPreviewLayer)
                    // When rotation is disabled, reset to portrait orientation (90°)
                    if let connection = uiView.videoPreviewLayer.connection,
                       connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                    uiView.videoPreviewLayer.videoGravity = .resizeAspectFill
                }
            }
        }
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        // Ensure we stop receiving rotation updates when this view goes away
        ChromaCameraManager.shared.detachPreviewLayerFromUIRotation(uiView.videoPreviewLayer)
    }

}

/// Backing UIView that hosts AVCaptureVideoPreviewLayer.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

