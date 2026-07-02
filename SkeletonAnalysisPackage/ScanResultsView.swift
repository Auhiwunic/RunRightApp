//
//  ScanResultsView.swift
//  RunRightApp
//

import SwiftUI

struct ScanResultsView: View {
    let result: GaitAnalysisResponse
    let shoeImage: UIImage
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Top Bar
                    topBar
                    
                    // Uploaded Shoe Image
                    ScanSectionHeader(title: "Uploaded Image")
                        .padding(.top, 24)
                    
                    Image(uiImage: shoeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    
                    ScanSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Gait Analysis
                    ScanSectionHeader(title: "Gait Analysis")
                        .padding(.top, 24)
                    
                    VStack(spacing: 12) {
                        if let left = result.leftFoot {
                            gaitAnalysisCard(title: "Left Foot", analysis: left)
                        }
                        
                        if let right = result.rightFoot {
                            gaitAnalysisCard(title: "Right Foot", analysis: right)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    ScanSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Overall Assessment
                    if let overall = result.overallGait {
                        ScanSectionHeader(title: "Overall Assessment")
                            .padding(.top, 24)
                        
                        Text(overall)
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.8))
                            .lineSpacing(6)
                            .padding(16)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(12)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                    
                    // Action Buttons
                    VStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Text("New Scan")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(AppTheme.accentColor)
                                .cornerRadius(12)
                        }
                        
                        Button(action: { dismiss() }) {
                            Text("Back to Scan")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    
                    // Bottom padding
                    Spacer().frame(height: 40)
                }
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        ZStack {
            // Gradient background
            ZStack {
                RadialGradient(
                    colors: [Color(hex: "#1a1a1a"), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 200
                )
                RadialGradient(
                    colors: [Color(hex: "#181818"), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 150
                )
            }
            .background(AppTheme.bgColor)
            
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .padding(8)
                }
                
                Text("Analysis Results")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                    .tracking(-0.3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .frame(height: 100)
    }
    
    // MARK: - Gait Analysis Card
    private func gaitAnalysisCard(title: String, analysis: FootAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.5)
                
                Spacer()
                
                Text(analysis.gaitType.capitalized)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(gaitTypeColor(analysis.gaitType))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(gaitTypeColor(analysis.gaitType).opacity(0.15))
                    .cornerRadius(6)
            }
            
            Text(analysis.analysis)
                .font(.system(size: 14, weight: .light))
                .foregroundColor(.white.opacity(0.8))
                .lineSpacing(6)
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }
    
    // MARK: - Helper Functions
    private func gaitTypeColor(_ gaitType: String) -> Color {
        switch gaitType.lowercased() {
        case "neutral":
            return AppTheme.accentGreen
        case "pronation", "supination":
            return Color(hex: "#FFD700")
        case "overpronation":
            return Color(hex: "#FF8C00")
        default:
            return .white
        }
    }
}

#Preview {
    ScanResultsView(
        result: GaitAnalysisResponse(
            shoeIdentification: nil,
            leftFoot: FootAnalysis(
                gaitType: "neutral", 
                confidence: 0, 
                analysis: "Wear pattern shows even distribution across the sole with moderate wear on the heel and forefoot. Light wear on the lateral edge suggests efficient load transfer. No significant interior collar wear detected."
            ),
            rightFoot: FootAnalysis(
                gaitType: "pronation", 
                confidence: 0, 
                analysis: "Heavy medial heel wear and moderate medial forefoot wear indicate pronation. Interior heel counter shows wear on the medial side, consistent with inward foot roll during gait."
            ),
            overallGait: "Overall, you have a relatively neutral left foot with mild pronation on the right foot. The asymmetry suggests you may benefit from stability features on the right side. Interior wear patterns confirm the external sole analysis.",
            overallConfidence: 0
        ),
        shoeImage: UIImage(systemName: "photo")!
    )
}

