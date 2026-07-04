//
//  ShoeCameraView.swift
//  RunRightApp
//
//  Guided capture for shoe soles — top-down framing guide, level indicator,
//  torch, and a library fallback. Consistent capture = consistent AI analysis.

import SwiftUI
import AVFoundation
import CoreMotion
import PhotosUI

// MARK: - Camera Controller

@MainActor
final class ShoeCameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isAvailable = false      // back camera exists and is configured
    @Published var isAuthorized = true      // camera permission granted
    @Published var isLevel = false          // phone held flat, camera pointing down
    @Published var isTorchOn = false

    private let motion = CMMotionManager()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var captureCompletion: ((UIImage?) -> Void)?
    private var configured = false

    func start() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            guard granted else { return }
            configureIfNeeded()
            guard isAvailable else { return }
            let session = self.session
            Task.detached { session.startRunning() }   // startRunning blocks — keep off main
            startMotionUpdates()
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        setTorch(false)
        let session = self.session
        Task.detached { if session.isRunning { session.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else {
            isAvailable = device != nil
            return
        }
        configured = true

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            isAvailable = false   // simulator or no back camera
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        self.device = device
        isAvailable = true
    }

    private func startMotionUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            // Flat with screen up (camera straight down) → gravity ≈ (0, 0, -1)
            self?.isLevel = gravity.z < -0.80
        }
    }

    func toggleTorch() {
        setTorch(!isTorchOn)
    }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = on
        } catch { /* torch is best-effort */ }
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
}

extension ShoeCameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            self.captureCompletion?(image)
            self.captureCompletion = nil
        }
    }
}

// MARK: - Preview Layer

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Guided Capture View

struct ShoeCameraView: View {
    let side: String                    // "left" | "right"
    let onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ShoeCameraController()
    @State private var libraryItem: PhotosPickerItem?
    @State private var previewImage: UIImage?    // non-nil = confirm stage

    private let accentLime = AppTheme.accentColor

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = previewImage {
                confirmStage(image)
            } else if camera.isAvailable {
                captureStage
            } else {
                fallbackStage
            }
        }
        .statusBarHidden()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: libraryItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    previewImage = image
                }
            }
        }
    }

    // MARK: Capture stage — live camera + guides

    private var captureStage: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Sole framing guide — turns lime when the phone is level
            GeometryReader { geo in
                let guideHeight = min(geo.size.height * 0.52, 430)
                let guideWidth = guideHeight * 0.44
                RoundedRectangle(cornerRadius: guideWidth * 0.5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
                    .foregroundColor(camera.isLevel ? accentLime : .white.opacity(0.65))
                    .frame(width: guideWidth, height: guideHeight)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .animation(.easeInOut(duration: 0.2), value: camera.isLevel)
            }

            VStack {
                // Top bar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark").accessibilityLabel("Close")
                            .font(AppTheme.head(15))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    Spacer()
                    Text("Scan \(side.capitalized) Sole")
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { camera.toggleTorch() }) {
                        Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt.slash")
                            .font(AppTheme.head(15))
                            .foregroundColor(camera.isTorchOn ? accentLime : .white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Level hint
                HStack(spacing: 6) {
                    Image(systemName: camera.isLevel ? "checkmark.circle.fill" : "level")
                        .font(AppTheme.bodySemibold(12))
                    Text(camera.isLevel ? "Level — good to go" : "Hold phone flat above the shoe")
                        .font(AppTheme.bodySemibold(12))
                }
                .foregroundColor(camera.isLevel ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(camera.isLevel ? accentLime : Color.black.opacity(0.45))
                .clipShape(Capsule())
                .padding(.top, 10)
                .animation(.easeInOut(duration: 0.2), value: camera.isLevel)

                Spacer()

                Text("Fill the outline with the sole, toe at the top")
                    .font(AppTheme.bodyMedium(12))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(.bottom, 14)

                // Bottom controls: library — shutter — spacer
                HStack {
                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(AppTheme.body(19))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button(action: {
                        camera.capture { image in
                            if let image { previewImage = image }
                        }
                    }) {
                        ZStack {
                            Circle()
                                .strokeBorder(camera.isLevel ? accentLime : Color.white, lineWidth: 4)
                                .frame(width: 74, height: 74)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                        }
                    }

                    Spacer()

                    // symmetry placeholder so the shutter stays centered
                    Color.clear.frame(width: 46, height: 46)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: Confirm stage — retake or use

    private func confirmStage(_ image: UIImage) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .cornerRadius(20)
                .padding(.horizontal, 24)

            Spacer()

            HStack(spacing: 14) {
                Button(action: {
                    previewImage = nil
                    libraryItem = nil
                }) {
                    Text("Retake")
                        .font(AppTheme.bodySemibold(15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(16)
                }

                Button(action: {
                    dismiss()
                    onCapture(image)
                }) {
                    Text("Use Photo")
                        .font(AppTheme.bodySemibold(15))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(accentLime)
                        .cornerRadius(16)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    // MARK: Fallback stage — simulator or permission denied

    private var fallbackStage: some View {
        VStack(spacing: 18) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark").accessibilityLabel("Close")
                        .font(AppTheme.head(15))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            Image(systemName: "camera.fill")
                .font(AppTheme.body(40))
                .foregroundColor(.white.opacity(0.3))

            Text(camera.isAuthorized
                 ? "Camera not available on this device."
                 : "Camera access is off. Enable it in Settings, or pick a photo instead.")
                .font(AppTheme.body(14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            PhotosPicker(selection: $libraryItem, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(accentLime)
                    .cornerRadius(16)
            }

            Spacer()
        }
    }
}
