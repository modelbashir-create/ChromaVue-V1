//
//  SettingsView.swift
//  ChromaVue
//
//  Enhanced with iOS 18+ design patterns and accessibility
//  Created by Mohamed Elbashir on 11/1/25.
//

import SwiftUI

enum UsageMode: String, CaseIterable, Identifiable {
    case clinical
    case training

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clinical: return "Clinical"
        case .training: return "Training"
        }
    }
}

private struct SettingsTokens {
    static let hairline = Color.white.opacity(0.15)
    static let brand = Color(red: 0.02, green: 0.25, blue: 0.55)
    static let hudAnim: Double = 0.12
}

struct SettingsView: View {
    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model = ChromaModelManager.shared
    @ObservedObject var export = DataExportManager.shared
    @ObservedObject var cam = ChromaCameraManager.shared
    @ObservedObject var analysis = AnalysisManager.shared
    
    @AppStorage("usageMode") private var usageModeRaw: String = UsageMode.clinical.rawValue
    @State private var clinicalFlashMode: ChromaCameraManager.FlashMode = .alternating
    
    private var currentUsageMode: UsageMode {
        UsageMode(rawValue: usageModeRaw) ?? .clinical
    }

    private func updateCameraFlashConfiguration() {
        switch currentUsageMode {
        case .clinical:
            cam.applyFlashMode(clinicalFlashMode)
        case .training:
            cam.applyFlashMode(.alternating)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection

                if model.developerMode {
                    developerSection
                }

                captureSection
                aboutSection
            }
            .accessibilityElement(children: .contain)
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(SettingsTokens.hairline, lineWidth: 1))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .onAppear {
            updateCameraFlashConfiguration()
        }
        .onChange(of: usageModeRaw) { _, _ in
            updateCameraFlashConfiguration()
        }
        .onChange(of: clinicalFlashMode) { _, _ in
            updateCameraFlashConfiguration()
        }
    }
    
    // MARK: - Section Builders

    @ViewBuilder
    private var generalSection: some View {
        Section {
            settingRow(
                title: "Developer Mode",
                subtitle: "Enables advanced diagnostics and export options",
                systemImage: "wrench.and.screwdriver"
            ) {
                Toggle("Developer Mode", isOn: $model.developerMode)
                    .labelsHidden()
            }
            settingRow(
                title: "App Mode",
                subtitle: "Choose between Clinical and Training behavior",
                systemImage: "stethoscope"
            ) {
                Picker("App Mode", selection: Binding(
                    get: { currentUsageMode },
                    set: { usageModeRaw = $0.rawValue }
                )) {
                    ForEach(UsageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Label("General", systemImage: "gear")
                .foregroundStyle(.primary)
                .font(.headline)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(SettingsTokens.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var developerSection: some View {
        Section {
            settingRow(
                title: "Manual Flash",
                subtitle: "Direct flash control for testing",
                systemImage: "flashlight.on.fill"
            ) {
                Toggle("Flash State", isOn: Binding(
                    get: { cam.isFlashOn },
                    set: { cam.setFlash($0) }
                ))
                .labelsHidden()
            }

            settingRow(
                title: "GPU Acceleration",
                subtitle: "Use MPSGraph on GPU for scalar analysis",
                systemImage: "cpu"
            ) {
                Toggle("Use GPU", isOn: $analysis.useGPUAcceleration)
                    .labelsHidden()
            }
            
            settingRow(
                title: "Model State",
                subtitle: "Simulate model loading for UI testing",
                systemImage: "brain.head.profile"
            ) {
                Toggle("Model Loaded", isOn: Binding(
                    get: { model.isLoaded },
                    set: { model.isLoaded = $0 }
                ))
                .labelsHidden()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Image(systemName: "waveform.path")
                        .font(.title2)
                        .foregroundStyle(SettingsTokens.brand)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heatmap Interpolation")
                            .font(.body)
                            .fontWeight(.medium)
                        
                        Text("Rendering quality for heatmap overlay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                Picker("Heatmap Interpolation", selection: $model.interpolationMode) {
                    Text("None").tag(ChromaModelManager.Interp.none)
                    Text("Low").tag(ChromaModelManager.Interp.low)
                    Text("High").tag(ChromaModelManager.Interp.high)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Toggle(isOn: $model.experimental3DHeatmap) {
                    Text("Experimental 3D Heatmap")
                        .font(.subheadline)
                }
                .tint(SettingsTokens.brand)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(SettingsTokens.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        } header: {
            Label("Developer", systemImage: "hammer")
                .foregroundStyle(.primary)
                .font(.headline)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(SettingsTokens.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        Section {
            if currentUsageMode == .clinical {
                settingRow(
                    title: "Flash Mode",
                    subtitle: "Controls how the flash behaves during capture",
                    systemImage: "flashlight.on.fill"
                ) {
                    Picker("Flash Mode", selection: $clinicalFlashMode) {
                        Text("Off").tag(ChromaCameraManager.FlashMode.off)
                        Text("On").tag(ChromaCameraManager.FlashMode.on)
                        Text("Alternating").tag(ChromaCameraManager.FlashMode.alternating)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                settingRow(
                    title: "Flash Mode",
                    subtitle: "Training Mode uses automatic alternating flash for ON/OFF pairs",
                    systemImage: "flashlight.on.fill"
                ) {
                    Text("Alternating")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if model.developerMode {
                settingRow(
                    title: "CSV Summary",
                    subtitle: "Writes measurement data to CSV format",
                    systemImage: "doc.text"
                ) {
                    Toggle("Write CSV Summary", isOn: $export.writeCSV)
                        .labelsHidden()
                }

                settingRow(
                    title: "RAW",
                    subtitle: "Save RAW DNG stills during Training captures",
                    systemImage: "square.stack.3d.up.fill"
                ) {
                    Toggle("Save RAW Stills", isOn: Binding(
                        get: { cam.saveRawStill },
                        set: { cam.saveRawStill = $0 }
                    ))
                    .labelsHidden()
                }

                settingRow(
                    title: "HEIC",
                    subtitle: "Save HEIC stills alongside RAW during Training",
                    systemImage: "photo.on.rectangle"
                ) {
                    Toggle("Save HEIC Sidecar", isOn: $cam.saveHEICSidecar)
                        .labelsHidden()
                }

                settingRow(
                    title: "Heatmap PNG",
                    subtitle: "Saves visual heatmap images (currently disabled)",
                    systemImage: "photo"
                ) {
                    Toggle("Save Heatmap PNG", isOn: $export.saveHeatmapPNG)
                        .labelsHidden()
                }
            }
        } header: {
            Label("Capture", systemImage: "camera")
                .foregroundStyle(.primary)
                .font(.headline)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(SettingsTokens.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            aboutCard(title: "App Version", value: appVersionString, systemImage: "app.badge")
            aboutCard(title: "Device", value: UIDevice.current.model, systemImage: "iphone")
            aboutCard(title: "iOS", value: UIDevice.current.systemVersion, systemImage: "gear.badge")
        } header: {
            Label("About", systemImage: "info.circle")
                .foregroundStyle(.primary)
                .font(.headline)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(SettingsTokens.hairline, lineWidth: 1))
        }
    }

    // MARK: - Modern Setting Components
    
    @ViewBuilder
    private func settingRow<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(SettingsTokens.brand)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            
            Spacer()
            
            content()
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SettingsTokens.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
    
    @ViewBuilder
    private func aboutCard(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(SettingsTokens.brand)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SettingsTokens.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}
