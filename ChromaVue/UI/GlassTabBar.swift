//
//  GlassTabBar.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/1/25.
//

import SwiftUI

private struct TabTokens {
    static let hairline = Color.white.opacity(0.15)
    static let brandAccent = Color(red: 0.02, green: 0.25, blue: 0.55)
}

enum AppTab: String, CaseIterable, Identifiable {
    case scan, history, help, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan:     return "Scan"
        case .history:  return "History"
        case .help:     return "Help"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .scan:     return "viewfinder"
        case .history:  return "clock"
        case .help:     return "questionmark.circle"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Modern Liquid Glass Tab Bar (iOS 18+)
struct LiquidGlassTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases) { tab in
                modernTabButton(tab)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation tabs")
    }

    @ViewBuilder
    private func modernTabButton(_ tab: AppTab) -> some View {
        Button {
            let animationStyle: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)
            withAnimation(animationStyle) {
                selection = tab
            }
            
            // Modern haptic feedback
            if #available(iOS 17.0, *) {
                let impact = UIImpactFeedbackGenerator(style: .soft)
                impact.impactOccurred(intensity: 0.7)
            } else {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: selection == tab)
                
                Text(tab.title)
                    .font(.footnote.weight(.semibold))
            }
            .frame(minWidth: 68, minHeight: 44)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .foregroundStyle(selection == tab ? .primary : .secondary)
            .background {
                if selection == tab {
                    Capsule()
                        .glassEffect(.regular, in: Capsule())
                        .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityHint(selection == tab ? "Selected" : "Tap to switch to \(tab.title)")
    }
}
