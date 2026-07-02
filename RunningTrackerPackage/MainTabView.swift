//
//  MainTabView.swift
//  RunRightApp
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 2 // Home is center (index 2)
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab Content - takes full screen
            TabView(selection: $selectedTab) {
                AnalyzeView()
                    .tag(0)
                
                ScanView()
                    .tag(1)
                
                HomeView()
                    .tag(2)
                
                RunView()
                    .tag(3)
                
                ProfileView()
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            // Custom Tab Bar - sits above safe area, doesn't block swipe
            CustomTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(.keyboard)
        .background(AppTheme.bgColor)
    }
}

// MARK: - Custom Tab Bar (respects safe area, doesn't block swipe up)
struct CustomTabBar: View {
    @Binding var selectedTab: Int
    
    private let tabs: [(icon: String, label: String)] = [
        ("chart.bar.fill", "Analyze"),
        ("magnifyingglass", "Scan"),
        ("house.fill", "Home"),
        ("figure.run", "Run"),
        ("person.fill", "Profile")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    TabBarItem(
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

struct TabBarItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(isSelected ? .white : .white.opacity(0.4))
            
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    MainTabView()
}
