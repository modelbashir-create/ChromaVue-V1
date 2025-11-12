//
//  ChromaVueApp.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 10/31/25.
//

import SwiftUI
import AVFoundation

@main
struct ChromaVueApp: App {
    @StateObject private var startupCoordinator = StartupCoordinator()
    
    var body: some Scene {
        WindowGroup {
            Group {
                if startupCoordinator.state == .ready {
                    ContentView()
                } else if startupCoordinator.state == .blockedPermission {
                    PermissionViewContainer()
                } else {
                    LaunchOverlay(startup: startupCoordinator)
                }
            }
            .preferredColorScheme(nil) // Respect system setting
            .onAppear {
                startupCoordinator.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Re-check permissions when app becomes active
                if startupCoordinator.state == .blockedPermission {
                    startupCoordinator.start()
                }
            }
        }
    }
}

// Wrapper to avoid ambiguous reference
struct PermissionViewContainer: View {
    @State private var hasPermission = false
    
    var body: some View {
        PermissionView(hasPermission: $hasPermission)
    }
}


// MARK: - Future Enhancement: Assistive Access Support
// Uncomment when targeting iOS 17+ minimum deployment target
/*
@available(iOS 17.0, *)
extension ChromaVueApp {
    var assistiveAccessScene: some Scene {
        AssistiveAccess {
            AssistiveAccessContentView()
        }
    }
}

@available(iOS 17.0, *)
struct AssistiveAccessContentView: View {
    @ObservedObject private var cam = ChromaCameraManager.shared
    @State private var isScanning = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                // Large, clear scanning button
                Button {
                    if isScanning {
                        cam.stopSession()
                    } else {
                        cam.startSession()
                    }
                    isScanning.toggle()
                } label: {
                    VStack(spacing: 16) {
                        Image(systemName: isScanning ? "stop.fill" : "camera.viewfinder")
                            .font(.system(size: 60, weight: .medium))
                        
                        Text(isScanning ? "Stop Scanning" : "Start Scanning")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(.regularMaterial, in: .rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                
                // Simple status indicator
                if isScanning {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 12, height: 12)
                        Text("Scanning Active")
                            .font(.title3)
                    }
                }
            }
            .padding(40)
            .navigationTitle("ChromaVue")
            .assistiveAccessNavigationIcon(systemImage: "camera.viewfinder")
        }
    }
}
*/
