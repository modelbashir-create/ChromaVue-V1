//  LaunchOverlay.swift
//  ChromaVue
//
//  A lightweight, brandable loading overlay for app startup.
//  Shows a progress ring and a 5-item checklist. VoiceOver-friendly.

import SwiftUI

struct LaunchOverlay: View {
    @ObservedObject var startup: StartupCoordinator
    var brandTitle: String = "ChromaVue"

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "aqi.medium") // placeholder logo
                        .font(.system(size: 56, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                    Text(brandTitle).font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, 12)

                // Progress
                VStack(spacing: 6) {
                    ProgressView(value: startup.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text(statusLine(startup.state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(statusLine(startup.state))
                }

                // Checklist
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(startup.checklist.keys).sorted(), id: \.self) { key in
                        let ok = startup.checklist[key] ?? false
                        HStack(spacing: 8) {
                            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(ok ? .green : .secondary)
                            Text(key)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 360)

                // Permission help / actions
                if startup.state == .blockedPermission {
                    VStack(spacing: 10) {
                        Text("Camera access is required to continue.")
                            .font(.callout)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString),
                               UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                                .padding(.vertical, 10).padding(.horizontal, 16)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(20)
            .frame(maxWidth: 480)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing ChromaVue")
    }

    private func statusLine(_ s: StartupCoordinator.State) -> String {
        switch s {
        case .idle: return "Idle"
        case .checkingPermissions: return "Checking camera permission"
        case .requestingPermissions: return "Requesting camera permission"
        case .configuringSession: return "Configuring camera"
        case .startingDepth: return "Starting sensors"
        case .loadingModel: return "Loading model"
        case .ready: return "Ready"
        case .blockedPermission: return "Permission required"
        case .failed(let message): return "Error: \(message)"
        }
    }
}
