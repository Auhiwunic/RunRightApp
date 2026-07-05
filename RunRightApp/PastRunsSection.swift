//
//  PastRunsSection.swift
//  RunRightApp
//
//  Past runs on the Run tab: a route-map "screenshot" + short stats per run.
//  Matches the dark dashboard theme (#2A2A2E cards, monospaced labels).
//

import SwiftUI
import MapKit
import CoreLocation
import FirebaseAuth

// MARK: - Model

struct PastRunItem: Identifiable {
    let id: String
    let date: Date
    let distanceMiles: Double
    let durationSeconds: TimeInterval
    let route: [CLLocationCoordinate2D]
    let dto: RunSummaryDTO?

    init(id: String, date: Date, distanceMiles: Double, durationSeconds: TimeInterval,
         route: [CLLocationCoordinate2D], dto: RunSummaryDTO?) {
        self.id = id; self.date = date; self.distanceMiles = distanceMiles
        self.durationSeconds = durationSeconds; self.route = route; self.dto = dto
    }

    /// Build from a stored run summary. Real app-recorded runs carry a
    /// downsampled GPS route (→ a real map thumbnail); HealthKit imports and
    /// treadmill runs have none (→ the placeholder).
    init(dto: RunSummaryDTO) {
        self.id = dto.runId
        self.date = dto.startTime
        self.distanceMiles = dto.distanceMeters / 1609.34
        self.durationSeconds = dto.durationSeconds
        self.route = dto.routeCoordinates
        self.dto = dto
    }

    var distanceText: String { String(format: "%.2f", distanceMiles) }

    var paceText: String {
        guard distanceMiles > 0 else { return "--" }
        let secPerMile = durationSeconds / distanceMiles
        let m = Int(secPerMile) / 60, s = Int(secPerMile) % 60
        return String(format: "%d:%02d", m, s)
    }

    var durationText: String {
        let t = max(0, Int(durationSeconds)); let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var dateText: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date).uppercased()
    }

    /// A DTO for the detail screen (synthesized for sample runs).
    var detailDTO: RunSummaryDTO {
        dto ?? RunSummaryDTO(
            runId: id, startTime: date,
            distanceMeters: distanceMiles * 1609.34,
            durationSeconds: durationSeconds,
            avgSpeedMps: durationSeconds > 0 ? (distanceMiles * 1609.34) / durationSeconds : 0,
            avgHeartRateBpm: nil, shoeName: nil, source: "app"
        )
    }
}

// MARK: - Sample data (for preview / emulation when there are no real runs)

enum SampleRuns {
    /// A wobbly closed loop around a center — reads like a real GPS track.
    private static func loop(center: CLLocationCoordinate2D, scale: Double, seed: Double, points: Int = 70) -> [CLLocationCoordinate2D] {
        (0...points).map { i in
            let t = Double(i) / Double(points) * 2 * .pi
            let r = scale * (1 + 0.34 * sin(3 * t + seed) + 0.14 * cos(5 * t + seed))
            return CLLocationCoordinate2D(
                latitude: center.latitude + r * sin(t),
                longitude: center.longitude + r * cos(t) * 1.25
            )
        }
    }

    static func items(reference: Date = Date()) -> [PastRunItem] {
        let day: TimeInterval = 86_400
        return [
            PastRunItem(
                id: "sample-1", date: reference.addingTimeInterval(-1 * day),
                distanceMiles: 4.12, durationSeconds: 33 * 60 + 48,
                route: loop(center: .init(latitude: 40.7829, longitude: -73.9654), scale: 0.0065, seed: 0.4),
                dto: nil),
            PastRunItem(
                id: "sample-2", date: reference.addingTimeInterval(-3 * day),
                distanceMiles: 6.31, durationSeconds: 52 * 60 + 10,
                route: loop(center: .init(latitude: 37.7694, longitude: -122.4862), scale: 0.0085, seed: 1.7),
                dto: nil),
            PastRunItem(
                id: "sample-3", date: reference.addingTimeInterval(-5 * day),
                distanceMiles: 3.05, durationSeconds: 26 * 60 + 5,
                route: loop(center: .init(latitude: 34.0118, longitude: -118.4954), scale: 0.0052, seed: 2.9),
                dto: nil),
            PastRunItem(
                id: "sample-4", date: reference.addingTimeInterval(-8 * day),
                distanceMiles: 9.84, durationSeconds: 81 * 60 + 32,
                route: loop(center: .init(latitude: 41.8838, longitude: -87.6270), scale: 0.011, seed: 4.2),
                dto: nil)
        ]
    }
}

// MARK: - Map thumbnail (the per-run "screenshot")

struct RunMapThumbnail: View {
    let route: [CLLocationCoordinate2D]
    var width: CGFloat = 150
    var height: CGFloat = 96

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AppTheme.cardBgAlt
                Image(systemName: route.count > 1 ? "map" : "figure.run")
                    .font(AppTheme.body(22))
                    .foregroundColor(AppTheme.primaryText.opacity(0.22))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.primaryText.opacity(0.08), lineWidth: 1)
        )
        .task(id: id) { await render() }
    }

    private var id: String { route.map { "\($0.latitude),\($0.longitude)" }.joined().hashValue.description }

    private func render() async {
        guard route.count > 1, image == nil else { return }
        let rendered = await Self.snapshot(route: route, size: CGSize(width: width, height: height))
        if let rendered { await MainActor.run { image = rendered } }
    }

    static func snapshot(route: [CLLocationCoordinate2D], size: CGSize) async -> UIImage? {
        guard route.count > 1 else { return nil }
        var minLat = route[0].latitude, maxLat = route[0].latitude
        var minLon = route[0].longitude, maxLon = route[0].longitude
        for c in route {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.45 + 0.002,
            longitudeDelta: (maxLon - minLon) * 1.45 + 0.002)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        options.scale = 2
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)   // match the app's dark theme

        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, _ in
                guard let snapshot else { cont.resume(returning: nil); return }
                let renderer = UIGraphicsImageRenderer(size: size)
                let img = renderer.image { _ in
                    snapshot.image.draw(at: .zero)
                    let path = UIBezierPath()
                    for (i, c) in route.enumerated() {
                        let p = snapshot.point(for: c)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.lineWidth = 3.5
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    UIColor(AppTheme.accentColor).setStroke()  // signature blue route line
                    path.stroke()
                }
                cont.resume(returning: img)
            }
        }
    }
}

// MARK: - Card + section

struct PastRunCard: View {
    let item: PastRunItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RunMapThumbnail(route: item.route)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.distanceText)
                    .font(AppTheme.display(26))
                    .foregroundColor(AppTheme.primaryText)
                Text("mi")
                    .font(AppTheme.bodyMedium(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.45))
            }

            HStack(spacing: 14) {
                pastRunStat(item.paceText, "/mi")
                pastRunStat(item.durationText, "time")
            }

            Text(item.dateText)
                .font(AppTheme.meta(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .padding(12)
        .frame(width: 174, alignment: .leading)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 20, shadowRadius: 9, x: 5, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.primaryText.opacity(0.06), lineWidth: 1)
        )
    }

    private func pastRunStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(AppTheme.head(14))
                .foregroundColor(AppTheme.primaryText)
            Text(label)
                .font(AppTheme.meta(9))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
    }
}
