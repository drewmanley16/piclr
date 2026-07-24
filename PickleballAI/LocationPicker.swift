import SwiftUI
import MapKit
import CoreLocation

/// Finds pickleball courts near the user (MapKit local search around the current
/// location) and lets them pick one, use their current area, or type a place.
@MainActor
final class LocationSearchModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Place: Identifiable {
        let id = UUID()
        let name: String
        let subtitle: String
        let distanceLabel: String?
        let coordinate: CLLocationCoordinate2D?
    }

    @Published var results: [Place] = []
    @Published var isSearching = false
    @Published var permissionDenied = false
    @Published var currentArea: String?
    @Published var query = "pickleball court"

    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var searchTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            permissionDenied = true
            runSearch()          // still allow a non-local search
        }
    }

    /// Debounced re-search as the user edits the query.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { runSearch() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                permissionDenied = true
                runSearch()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
            self.reverseGeocode(loc)
            self.runSearch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.runSearch() }
    }

    private func reverseGeocode(_ loc: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let p = placemarks?.first else { return }
                self?.currentArea = [p.locality, p.administrativeArea]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            }
        }
    }

    private func runSearch() {
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let loc = location {
            request.region = MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 25_000,
                longitudinalMeters: 25_000
            )
        }
        let origin = location
        MKLocalSearch(request: request).start { [weak self] response, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSearching = false
                self.results = (response?.mapItems ?? []).prefix(25).map { item in
                    let distance = origin.flatMap { o in
                        item.placemark.location.map { o.distance(from: $0) / 1609.34 }
                    }
                    return Place(
                        name: item.name ?? "Court",
                        subtitle: [item.placemark.locality, item.placemark.administrativeArea]
                            .compactMap { $0 }.joined(separator: ", "),
                        distanceLabel: distance.map { String(format: "%.1f mi", $0) },
                        coordinate: item.placemark.location?.coordinate
                    )
                }
            }
        }
    }
}

struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocationSearchModel()
    @Binding var location: String
    @State private var manual = ""

    var body: some View {
        NavigationStack {
            List {
                if let area = model.currentArea {
                    Section {
                        Button {
                            location = area
                            dismiss()
                        } label: {
                            Label("Use my location: \(area)", systemImage: "location.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                Section("Nearby courts") {
                    if model.isSearching && model.results.isEmpty {
                        HStack { ProgressView().tint(Theme.accent); Text("Finding courts…").foregroundStyle(Theme.textSecondary) }
                    } else if model.results.isEmpty {
                        Text(model.permissionDenied
                             ? "Location is off. Search or type a place below."
                             : "No courts found nearby.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(model.results) { place in
                            Button {
                                location = place.name
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name)
                                            .foregroundStyle(Theme.textPrimary)
                                        if !place.subtitle.isEmpty {
                                            Text(place.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    if let d = place.distanceLabel {
                                        Text(d).font(.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Enter manually") {
                    HStack {
                        TextField("Location name", text: $manual)
                        Button("Set") {
                            location = manual.trimmingCharacters(in: .whitespaces)
                            dismiss()
                        }
                        .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $model.query, prompt: "Search courts or places")
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { model.start() }
        }
    }
}
