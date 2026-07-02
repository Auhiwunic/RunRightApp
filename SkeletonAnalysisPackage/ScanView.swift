//
//  ScanView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with OpenAIService backend

import SwiftUI
import PhotosUI

struct ScanView: View {
    @State private var selectedShoe = "Nike Pegasus 40"
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isAnalyzing = false
    @State private var analysisResult: GaitAnalysisResponse?
    @State private var errorMessage: String?
    @State private var showingResults = false
    
    private let shoes = ["Nike Pegasus 40", "Nike Vaporfly 3", "Brooks Ghost 15", "Hoka Clifton 9", "+ Add Shoe"]
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Top Bar
                    topBar
                    
                    // Wear Pattern Section
                    ScanSectionHeader(title: "Wear Pattern")
                        .padding(.top, 24)
                    heatmapContainer
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    ScanSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Gait Metrics Section
                    ScanSectionHeader(title: "Gait Metrics")
                        .padding(.top, 24)
                    statsRow
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    ScanSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Wear Trend Section
                    ScanSectionHeader(title: "Wear Trend")
                        .padding(.top, 24)
                    trendContainer
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    ScanSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // New Scan Section
                    ScanSectionHeader(title: "New Scan")
                        .padding(.top, 24)
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Text("Upload Shoe Photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
                            )
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    // Loading indicator
                    if isAnalyzing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(AppTheme.accentColor)
                            Text("Analyzing wear patterns...")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    // Error message
                    if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(Color(hex: "#FF8C00"))
                            
                            Text("Analysis Failed")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                            
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                            
                            Button("Try Again") {
                                if selectedImage != nil {
                                    analyzeImage()
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(AppTheme.accentColor)
                            .cornerRadius(8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    // Bottom padding for tab bar
                    Spacer().frame(height: 120)
                }
            }
        }
        .onChange(of: selectedItem) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        selectedImage = image
                        analysisResult = nil
                        errorMessage = nil
                        analyzeImage()
                    }
                }
            }
        }
        .sheet(isPresented: $showingResults) {
            if let result = analysisResult, let image = selectedImage {
                ScanResultsView(result: result, shoeImage: image)
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
            
            Text("Gait Analysis")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(AppTheme.primaryText)
                .tracking(-0.3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
        }
        .frame(height: 100)
    }
    
    // MARK: - Heatmap Container
    private var heatmapContainer: some View {
        VStack(spacing: 16) {
            // Shoe dropdown in top right
            HStack {
                Spacer()
                
                // Shoe dropdown
                Menu {
                    ForEach(shoes, id: \.self) { shoe in
                        Button(shoe) {
                            selectedShoe = shoe
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedShoe)
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.primaryText)
                        
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }
            }
            
            // Heatmaps
            HStack(spacing: 30) {
                FootHeatmapView(isLeft: true)
                FootHeatmapView(isLeft: false)
            }
            .frame(maxWidth: .infinity)
            
            // Legend - Smooth heatmap gradient
            HStack(spacing: 12) {
                LegendItemView(color: Color(hex: "#00CED1"), label: "Low")
                LegendItemView(color: Color(hex: "#00FA9A"), label: "")
                LegendItemView(color: Color(hex: "#7FFF00"), label: "")
                LegendItemView(color: Color(hex: "#FFD700"), label: "Med")
                LegendItemView(color: Color(hex: "#FF8C00"), label: "")
                LegendItemView(color: Color(hex: "#FF0000"), label: "High")
            }
        }
    }
    
    // MARK: - Stats Row
    private var statsRow: some View {
        HStack(spacing: 10) {
            ScanStatCard(
                icon: "checkmark.circle.fill",
                label: "Pronation",
                value: "Neutral"
            )
            
            ScanStatCard(
                icon: "arrow.left.and.right",
                label: "Symmetry",
                value: "87%",
                isSymmetry: true
            )
        }
    }
    
    // MARK: - Trend Container
    private var trendContainer: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                
                Text("Last 6 months")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.secondaryText)
            }
            
            // Trend Chart
            TrendChartView()
                .frame(height: 80)
            
            // X-axis labels
            HStack {
                ForEach(["AUG", "SEP", "OCT", "NOV", "DEC", "JAN"], id: \.self) { month in
                    Text(month)
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
    // MARK: - Actions
    private func analyzeImage() {
        guard let image = selectedImage else { return }
        
        isAnalyzing = true
        errorMessage = nil
        
        Task {
            do {
                let prefs: [String: String] = [:]
                let result = try await OpenAIService.shared.analyzeShoeImage(image, userPreferences: prefs)
                
                await MainActor.run {
                    analysisResult = result
                    isAnalyzing = false
                    showingResults = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAnalyzing = false
                }
            }
        }
    }
    
    private func resetView() {
        selectedItem = nil
        selectedImage = nil
        analysisResult = nil
        errorMessage = nil
        showingResults = false
    }
}

// MARK: - Foot Heatmap View
struct FootHeatmapView: View {
    let isLeft: Bool
    
    private let columns = 16
    private let rows = 33
    private let cellSize: CGFloat = 5
    private let cornerRadius: CGFloat = 1.5
    
    // Shoe shape data - pre-computed for performance
    // 1 = shoe cell, 0 = empty
    private let shoeShapeData: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    ]
    
    var body: some View {
        VStack(spacing: 8) {
            Text(isLeft ? "Left" : "Right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .textCase(.uppercase)
                .tracking(0.5)
            
            // Simple VStack + HStack grid (more reliable than LazyVGrid)
            VStack(spacing: 1) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<columns, id: \.self) { col in
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(getCellColor(row: row, col: col))
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }
    
    private func getCellColor(row: Int, col: Int) -> Color {
        // Get the actual column based on left/right foot
        let actualCol = isLeft ? (columns - 1 - col) : col
        
        // Check if this cell is part of the shoe shape
        guard row < shoeShapeData.count,
              actualCol < shoeShapeData[row].count,
              shoeShapeData[row][actualCol] == 1 else {
            return .clear
        }
        
        // Wear pattern logic - high wear at ball of foot and heel
        let isBallArea = row >= 6 && row <= 12   // Ball of foot (toes area)
        let isHeelArea = row >= 25 && row <= 30  // Heel area
        
        // Inside edge detection (where pronation wear shows)
        let isInnerEdge: Bool
        let isMidInner: Bool
        let isOuterEdge: Bool
        
        if isLeft {
            // Left foot - inner edge is on the right side (higher col values)
            isInnerEdge = col >= 10
            isMidInner = col >= 7 && col < 10
            isOuterEdge = col < 5
        } else {
            // Right foot - inner edge is on the left side (lower col values)
            isInnerEdge = col <= 5
            isMidInner = col > 5 && col <= 8
            isOuterEdge = col >= 11
        }
        
        // Smooth heatmap: Cyan (good) → Turquoise → Green → Lime → Yellow → Orange → Red (worst)
        // Level 7: Extreme wear - Red
        if isInnerEdge && (isBallArea || isHeelArea) {
            return Color(hex: "#FF0000")  // Red
        }
        // Level 6: Very high wear - Orange-Red
        else if isInnerEdge && !isBallArea && !isHeelArea {
            return Color(hex: "#FF4500")  // Orange-Red
        }
        // Level 5: High wear - Orange
        else if isMidInner && (isBallArea || isHeelArea) {
            return Color(hex: "#FF8C00")  // Orange
        }
        // Level 4: Medium-high wear - Yellow
        else if isMidInner {
            return Color(hex: "#FFD700")  // Yellow
        }
        // Level 3: Medium wear - Lime
        else if isBallArea || isHeelArea {
            return Color(hex: "#7FFF00")  // Lime/Chartreuse
        }
        // Level 2: Low wear - Spring Green
        else if !isOuterEdge {
            return Color(hex: "#00FA9A")  // Spring Green
        }
        // Level 1: Minimal wear - Cyan/Teal (good)
        else {
            return Color(hex: "#00CED1")  // Cyan/Turquoise
        }
    }
}

// MARK: - Legend Item
struct LegendItemView: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(AppTheme.secondaryText)
        }
    }
}

// MARK: - Scan Stat Card
struct ScanStatCard: View {
    let icon: String
    let label: String
    let value: String
    var isSymmetry: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(AppTheme.accentColor)
            
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            
            Text(value)
                .font(.system(size: 16, weight: .light))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Trend Chart View
struct TrendChartView: View {
    private let dataPoints: [CGFloat] = [0.5, 0.55, 0.48, 0.62, 0.65, 0.7, 0.75]
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = width / CGFloat(dataPoints.count - 1)
            
            ZStack {
                // Grid lines
                ForEach([0.25, 0.5, 0.75], id: \.self) { y in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * (1 - y)))
                        path.addLine(to: CGPoint(x: width, y: height * (1 - y)))
                    }
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
                
                // Area fill
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in dataPoints.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = height * (1 - value)
                        if index == 0 {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accentColor.opacity(0.25), AppTheme.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                // Line
                Path { path in
                    for (index, value) in dataPoints.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = height * (1 - value)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(AppTheme.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                
                // Dots
                ForEach(0..<dataPoints.count, id: \.self) { index in
                    let x = CGFloat(index) * stepX
                    let y = height * (1 - dataPoints[index])
                    let isLast = index == dataPoints.count - 1
                    
                    Circle()
                        .fill(isLast ? AppTheme.accentColor : AppTheme.bgColor)
                        .overlay(
                            Circle().stroke(AppTheme.accentColor, lineWidth: 2)
                        )
                        .frame(width: isLast ? 10 : 8, height: isLast ? 10 : 8)
                        .position(x: x, y: y)
                }
            }
        }
    }
}

// MARK: - Section Header (clean simple)
struct ScanSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .light))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }
}

// MARK: - Section Divider
struct ScanSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

#Preview {
    ScanView()
}

