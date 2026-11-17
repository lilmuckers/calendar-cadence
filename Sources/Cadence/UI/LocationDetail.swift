import CadenceCore
import MapKit
import SwiftUI

/// Map preview plus "~18 min drive" for an in-person meeting.
struct LocationDetail: View {
    @Environment(AppState.self) private var state
    let query: String
    let tint: Color
    let start: Date

    @State private var item: MKMapItem?
    @State private var resolving = true
    @State private var eta: TimeInterval?
    @State private var etaLoading = false
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(query, systemImage: "mappin.and.ellipse")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .textSelection(.enabled)

            if let item {
                Map(position: $position, interactionModes: [.zoom, .pan]) {
                    Marker(item.name ?? query, coordinate: TravelEstimator.coordinate(of: item))
                        .tint(tint)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))

                HStack(spacing: 8) {
                    travelChip
                    Spacer()
                    Button {
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode])
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
            } else if resolving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finding location…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Couldn't find this place on the map.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: query) { await resolve() }
        .task(id: "\(query)|\(state.prefs.travelMode.rawValue)|\(item != nil)") { await loadETA() }
    }

    private var travelChip: some View {
        Menu {
            Picker("Travel by", selection: Binding(get: { state.prefs.travelMode }, set: { state.prefs.travelMode = $0 })) {
                ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.prefs.travelMode.symbol)
                if etaLoading {
                    Text("Estimating…")
                } else if let eta {
                    Text("~\(CountdownFormatter.short(eta)) \(verb)").monospacedDigit()
                    if start.timeIntervalSince(state.now) > 0 {
                        Text(leaveHint(eta)).foregroundStyle(leaveColor(eta))
                    }
                } else if TravelEstimator.shared.isLocationDenied {
                    Text("Location off")
                } else {
                    Text("No estimate")
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var verb: String {
        switch state.prefs.travelMode {
        case .driving: "drive"
        case .walking: "walk"
        case .transit: "by transit"
        }
    }

    private var directionsMode: String {
        switch state.prefs.travelMode {
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        }
    }

    private func leaveHint(_ eta: TimeInterval) -> String {
        let slack = start.timeIntervalSince(state.now) - eta
        return slack <= 0 ? "· leave now" : "· leave in \(CountdownFormatter.short(slack))"
    }

    private func leaveColor(_ eta: TimeInterval) -> Color {
        let slack = start.timeIntervalSince(state.now) - eta
        return slack <= 300 ? .orange : .secondary
    }

    private func resolve() async {
        resolving = true
        let found = await TravelEstimator.shared.place(for: query)
        item = found
        if let found {
            position = .region(MKCoordinateRegion(
                center: TravelEstimator.coordinate(of: found),
                latitudinalMeters: 1200, longitudinalMeters: 1200
            ))
        }
        resolving = false
    }

    private func loadETA() async {
        guard let item else { return }
        etaLoading = true
        eta = await TravelEstimator.shared.eta(to: item, mode: state.prefs.travelMode, departing: Date())
        etaLoading = false
    }
}
