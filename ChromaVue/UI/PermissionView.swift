//
//  PermissionView.swift
//  ChromaVue
//
//  Camera permission request view for live color mapping
//

import SwiftUI
import AVFoundation

@MainActor
struct PermissionView: View {
    @Binding var hasPermission: Bool
    @State private var isRequesting = false
    
    var body: some View {
        VStack(spacing: 32) {
            // Branding
            VStack(spacing: 16) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 80, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                
                VStack(spacing: 8) {
                    Text("ChromaVue")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Color & Pattern Visualization")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Permission explanation
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text("Camera Access Required")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("ChromaVue needs camera access to capture color information from the skin and show live visual maps. This is an experimental visualization tool and is not a medical device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Features list
                VStack(alignment: .leading, spacing: 12) {
                    PermissionFeatureRow(
                        icon: "camera.macro",
                        title: "Real-time Analysis",
                        description: "Process live camera feed to build color-based maps"
                    )
                    
                    PermissionFeatureRow(
                        icon: "waveform.path.ecg",
                        title: "Live Visualization",
                        description: "Advanced algorithms for color and pattern analysis"
                    )
                    
                    PermissionFeatureRow(
                        icon: "lock.shield",
                        title: "Privacy Protected",
                        description: "All processing happens on your device"
                    )
                }
                .padding(.horizontal)
            }
            
            Spacer(minLength: 0)
            
            // Action buttons
            VStack(spacing: 16) {
                Button {
                    requestCameraPermission()
                } label: {
                    HStack {
                        if isRequesting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "camera")
                            Text("Enable Camera Access")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(isRequesting)
                
                Button {
                    openSettings()
                } label: {
                    Text("Open Settings")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            
            Text("ChromaVue is an experimental research tool. It is not intended for diagnosis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera permission required")
        .accessibilityAddTraits(.isModal)
    }
    
    private func requestCameraPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.isRequesting = false
                self.hasPermission = granted
                // If denied, the separate "Open Settings" button remains available for the user.
            }
        }
    }
    
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

private struct PermissionFeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
}

#Preview {
    PermissionView(hasPermission: .constant(false))
}
