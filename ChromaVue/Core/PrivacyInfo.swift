//
//  PrivacyInfo.swift
//  ChromaVue
//
//  Privacy configuration reference - Add these keys to your Info.plist via Xcode
//

/*
 Add these privacy usage descriptions to your ChromaVue target's Info.plist:
 
 In Xcode:
 1. Select your ChromaVue target
 2. Go to Info tab
 3. Add Custom iOS Target Properties:

 NSCameraUsageDescription:
 "ChromaVue needs camera access to capture medical imagery for oxygenation analysis. This enables real-time scanning and measurement capabilities."
 
 NSPhotoLibraryAddUsageDescription:
 "ChromaVue saves scan results to your photo library for medical documentation purposes."
 
 NSMicrophoneUsageDescription (optional):
 "ChromaVue may record audio notes alongside measurements for comprehensive medical documentation."
 
 UISupportsAssistiveAccess:
 true
 
 UIRequiredDeviceCapabilities:
 - camera-flash
 - still-camera
*/

import Foundation

// Privacy-related constants for the app
enum PrivacyStrings {
    static let cameraUsage = "ChromaVue needs camera access to capture medical imagery for oxygenation analysis. This enables real-time scanning and measurement capabilities."
    static let photoLibraryUsage = "ChromaVue saves scan results to your photo library for medical documentation purposes."
    static let microphoneUsage = "ChromaVue may record audio notes alongside measurements for comprehensive medical documentation."
}