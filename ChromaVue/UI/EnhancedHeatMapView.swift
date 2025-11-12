import SwiftUI

@MainActor
struct EnhancedHeatMapView: View {
    @EnvironmentObject var model: ChromaModelManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Live preview: uses the same scalarCI the main ContentView uses
                Group {
                    if let ci = model.scalarCI {
                        HeatmapOverlay(fullField: ci, interpolation: .low)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        VStack(spacing: 8) {
                            Text("No heatmap yet")
                                .font(.headline)
                            Text("Open the Scan tab and start the camera to see a live heatmap preview here.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal)

                // Controls that edit the shared heatmapConfig
                Form {
                    Section("Opacity") {
                        Slider(
                            value: Binding(
                                get: { Double(model.heatmapConfig.opacity) },
                                set: { model.heatmapConfig.opacity = CGFloat($0) }
                            ),
                            in: 0.0...1.0
                        ) {
                            Text("Overlay Opacity")
                        }
                        Text(String(format: "%.2f", model.heatmapConfig.opacity))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Color Map") {
                        Picker("Color Map", selection: $model.heatmapConfig.colorMap) {
                            ForEach(HeatmapColorMap.allCases) { map in
                                Text(map.displayName).tag(map)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("How this works") {
                        Text("These controls change how the heatmap overlay looks in the Scan tab. Start a scan and adjust the opacity and color map here to find a style that works best for you.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Heatmap Style")
        }
    }
}
