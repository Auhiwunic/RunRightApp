//
//  VideoSkeletonView.swift
//  RunRightApp
//
//  Video upload and skeleton overlay analysis view
//

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation

struct VideoSkeletonView: View {
    @StateObject private var processor = VideoProcessor()
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var showingVideoPicker = false
    @State private var player: AVPlayer?
    @State private var isPreparingVideo = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        Text("Running Form Analysis")
                            .font(.title2.bold())
                        Text("Upload a running video for skeleton overlay")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    
                    // Upload Section
                    if processor.processedVideoURL == nil && !processor.isProcessing {
                        uploadSection
                    }
                    
                    // Preparing/Processing Section
                    if isPreparingVideo || processor.isProcessing {
                        preparingOrProcessingSection
                    }
                    
                    // Error
                    if let error = processor.error {
                        errorSection(error: error)
                    }
                    
                    // Result Section
                    if let processedURL = processor.processedVideoURL {
                        resultSection(url: processedURL)
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationBarHidden(true)
            .background(Color(.systemGroupedBackground))
        }
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let newItem = newItem {
                    await loadVideo(from: newItem)
                }
            }
        }
    }
    
    // MARK: - Upload Section
    
    private var uploadSection: some View {
        VStack(spacing: 16) {
            // Video Picker
            PhotosPicker(
                selection: $selectedItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    Text("Select Running Video")
                        .font(.headline)
                    Text("Choose from your photo library")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(.blue.opacity(0.5))
                )
            }
            
            // Selected video preview
            if let videoURL = selectedVideoURL {
                VStack(spacing: 12) {
                    Text("Selected Video")
                        .font(.headline)
                    
                    VideoPlayer(player: AVPlayer(url: videoURL))
                        .frame(height: 200)
                        .cornerRadius(12)
                    
                    Button(action: { processVideo() }) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Analyze Running Form")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
            }
            
            // Tips
            tipsSection
        }
    }
    
    // MARK: - Processing Section
    
    private var preparingOrProcessingSection: some View {
        VStack(spacing: 16) {
            if isPreparingVideo {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
                Text("Preparing video...")
                    .font(.headline)
            } else {
                ProgressView(value: processor.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                Text("Processing... \(Int(processor.progress * 100))%")
                    .font(.headline)
                Text("Detecting body pose in each frame")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Animated skeleton icon
            Image(systemName: "figure.run")
                .font(.system(size: 60))
                .foregroundColor(.blue)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Error Section
    
    private func errorSection(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text("Error")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Try Again") {
                processor.error = nil
                selectedItem = nil
                selectedVideoURL = nil
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Result Section
    
    private func resultSection(url: URL) -> some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Analysis Complete")
                    .font(.headline)
            }
            
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 300)
                .cornerRadius(12)
            
            HStack(spacing: 12) {
                Button(action: { saveToPhotos(url: url) }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button(action: { resetView() }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("New Video")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                }
            }
            
            // Legend
            legendSection
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Tips Section
    
    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tips for Best Results")
                .font(.headline)
            
            TipRow(icon: "video", text: "Record from the side for best gait analysis")
            TipRow(icon: "sun.max", text: "Good lighting improves detection accuracy")
            TipRow(icon: "figure.run", text: "Full body visible in frame works best")
            TipRow(icon: "clock", text: "Shorter clips process faster")
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Legend Section
    
    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skeleton Colors")
                .font(.subheadline.bold())
            
            HStack(spacing: 16) {
                LegendItem(color: .cyan, label: "Left side")
                LegendItem(color: Color(hex: "#00FF7F"), label: "Right side")
                LegendItem(color: .yellow, label: "Head/Neck")
            }
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Actions
    
    private func loadVideo(from item: PhotosPickerItem) async {
        await MainActor.run {
            isPreparingVideo = true
        }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try data.write(to: tempURL)
                
                await MainActor.run {
                    selectedVideoURL = tempURL
                    isPreparingVideo = false
                }
            }
        } catch {
            await MainActor.run {
                processor.error = "Failed to load video: \(error.localizedDescription)"
                isPreparingVideo = false
            }
        }
    }
    
    private func processVideo() {
        guard let url = selectedVideoURL else { return }
        Task {
            await processor.processVideo(url: url)
        }
    }
    
    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        // Could show a toast/alert here
                    }
                }
            }
        }
    }
    
    private func resetView() {
        selectedItem = nil
        selectedVideoURL = nil
        processor.processedVideoURL = nil
        processor.error = nil
        processor.progress = 0
        isPreparingVideo = false
    }
}

// MARK: - Supporting Views

struct TipRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    VideoSkeletonView()
}

