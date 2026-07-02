//
//  SkeletonAnalysisTabView.swift
//  SkeletonAnalysisPackage
//

import SwiftUI

struct SkeletonAnalysisTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                AnalyzeView()
                    .tag(0)
                
                ScanView()
                    .tag(1)
                
                VideoSkeletonView()
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            SkeletonTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard)
        .background(AppTheme.bgColor)
    }
}

struct SkeletonTabBar: View {
    @Binding var selectedTab: Int
    
    private let tabs: [(icon: String, label: String)] = [
        ("chart.bar.fill", "Analyze"),
        ("magnifyingglass", "Scan"),
        ("figure.walk", "Review")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    SkeletonTabItem(
                        icon: tabs[index].icon,
                        label: tabs[index].label,
                        isSelected: selectedTab == index
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(AppTheme.tabBarBg)
    }
}

struct SkeletonTabItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(isSelected ? .white : .white.opacity(0.4))
            
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SkeletonAnalysisTabView()
}

