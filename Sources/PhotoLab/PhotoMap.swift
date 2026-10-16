import Foundation
import MapKit

/// A GPS position in degrees: north and east positive (`PhotoInfo`'s
/// latitude and longitude, `PHAsset.location`'s coordinate).
struct GeoPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One photo the map can place: its id and where it was taken.
struct LocatedPhoto: Equatable, Sendable {
    let id: Photo.ID
    let point: GeoPoint
}

/// The map's arithmetic, apart from any view: photos bucketed into pins
/// (SwiftUI's `Map` has no clustering on macOS 14) and the region that
/// frames them.
enum MapPins {
    /// One pin: the photos of one grid cell, in the order they were given
    /// (the visible order). Drawn at their mean position with the first
    /// photo's thumbnail and the count.
    struct Pin: Identifiable, Equatable {
        /// The cell, "row:column": stable while the cell size is.
        let id: String
        let coordinate: GeoPoint
        let photos: [Photo.ID]
        var first: Photo.ID { photos[0] }
        var count: Int { photos.count }
    }

    /// How many cells span the visible region's wider side: a pin is about
    /// a twelfth of the map wide, so neighbours rarely overlap.
    static let cellsAcross = 12.0

    /// The cell size for a visible span (degrees): the wider of the two
    /// deltas over `cellsAcross`, never zero.
    static func cellDegrees(latitudeDelta: Double, longitudeDelta: Double) -> Double {
        max(max(latitudeDelta, longitudeDelta) / cellsAcross, 1e-7)
    }

    /// The photos bucketed into square cells of `cellDegrees` (floor of
    /// latitude and longitude over the size): one pin per non-empty cell,
    /// every photo of the cell in it, pins in the order of their first
    /// photo.
    static func group(_ located: [LocatedPhoto], cellDegrees: Double) -> [Pin] {
        struct Cell: Hashable { let row: Int, column: Int }
        var order: [Cell] = []
        var members: [Cell: [LocatedPhoto]] = [:]
        for photo in located {
            let cell = Cell(row: Int((photo.point.latitude / cellDegrees).rounded(.down)),
                            column: Int((photo.point.longitude / cellDegrees).rounded(.down)))
            if members[cell] == nil { order.append(cell) }
            members[cell, default: []].append(photo)
        }
        return order.map { cell in
            let photos = members[cell]!
            let n = Double(photos.count)
            let mean = GeoPoint(latitude: photos.reduce(0) { $0 + $1.point.latitude } / n,
                                longitude: photos.reduce(0) { $0 + $1.point.longitude } / n)
            return Pin(id: "\(cell.row):\(cell.column)", coordinate: mean, photos: photos.map(\.id))
        }
    }

    /// The fitted span is this much wider than the points' own extent, so
    /// no pin sits on the edge.
    static let padding = 1.3
    /// The smallest span shown (metres), about a neighbourhood: one photo,
    /// or several taken in one spot, frame at this.
    static let minimumSpanMeters = 1_000.0
    /// Metres in a degree of latitude.
    static let metersPerDegree = 111_320.0

    /// A region holding every point with `padding` around them, centred on
    /// their extent; at least `minimumSpanMeters` across; nil with no
    /// points.
    static func region(fitting points: [GeoPoint]) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points.dropFirst() {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = GeoPoint(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let minLatDelta = minimumSpanMeters / metersPerDegree
        // A degree of longitude shrinks with the latitude's cosine.
        let minLonDelta = minLatDelta / max(cos(center.latitude * .pi / 180), 0.01)
        let latDelta = min(max((maxLat - minLat) * padding, minLatDelta), 180)
        let lonDelta = min(max((maxLon - minLon) * padding, minLonDelta), 360)
        return MKCoordinateRegion(center: center.coordinate,
                                  span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}

/// Where the open source's photos were taken, for the map (View › Map).
/// A Photos asset's position comes with the listing (`Photo.location`, no
/// read); a folder photo's from its header, through the Info section's
/// `PhotoInfoStore`, so a photo whose info is already cached is not read
/// again and one the map reads is not read again by Info. The reads are one
/// background pass (`start`), a file at a time, started when the map opens
/// and stopped by `cancel` (leaving the map, or an `open`); a stopped pass
/// keeps what it read.
@MainActor
@Observable
final class PhotoLocations {
    /// Every position known for the open source.
    private(set) var points: [Photo.ID: GeoPoint] = [:]
    /// The running pass: files read so far of how many it set out to read;
    /// nil when no pass runs.
    private(set) var reading: (done: Int, total: Int)?
    @ObservationIgnored private var pass: Task<Void, Never>?
    /// Bumped by every start and cancel: a stopped pass writes nothing more.
    @ObservationIgnored private var generation = 0

    /// Collects the positions of `photos`: the listing's and the cached
    /// infos' at once, then a pass reading every other photo with a file.
    /// A pass already running is cancelled first.
    func start(_ photos: [Photo], store: PhotoInfoStore) {
        cancel()
        points = [:]
        var unread: [Photo] = []
        for photo in photos {
            if let point = photo.location {
                points[photo.id] = point
            } else if let info = store.cached(photo.id) {
                record(info, for: photo.id)
            } else if photo.fileURL != nil {
                unread.append(photo)
            }
        }
        guard !unread.isEmpty else { return }
        let generation = generation
        reading = (0, unread.count)
        pass = Task { [weak self] in
            for (i, photo) in unread.enumerated() {
                if Task.isCancelled { return }
                let info = await store.info(for: photo, file: photo.fileURL)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.record(info, for: photo.id)
                self.reading = (i + 1, unread.count)
            }
            guard let self, generation == self.generation else { return }
            self.reading = nil
            self.pass = nil
        }
    }

    /// Stops the pass after the file in flight; what it read stays. The
    /// stopped task is kept until the next start, for `waitForPass`.
    func cancel() {
        generation += 1
        pass?.cancel()
        reading = nil
    }

    /// A new source: no pass, no positions.
    func reset() {
        cancel()
        points = [:]
    }

    /// Waits for the last pass, running or stopped, to return (tests).
    func waitForPass() async {
        await pass?.value
    }

    /// The photos of `photos` with a known position, in their order.
    func located(in photos: [Photo]) -> [LocatedPhoto] {
        photos.compactMap { photo in points[photo.id].map { LocatedPhoto(id: photo.id, point: $0) } }
    }

    /// The map's footer: "3 of 40 photos have a location".
    static func summary(located: Int, of total: Int) -> String {
        total == 1 ? "\(located) of 1 photo has a location" : "\(located) of \(total) photos have a location"
    }

    private func record(_ info: PhotoInfo, for id: Photo.ID) {
        if let latitude = info.latitude, let longitude = info.longitude {
            points[id] = GeoPoint(latitude: latitude, longitude: longitude)
        }
    }
}

extension Library {
    /// A click on a map pin: its photos selected, the first the anchor.
    func clickPin(_ pin: MapPins.Pin) {
        select(pin.photos)
    }

    /// A double-click on a map pin: the loupe on its first photo, the pin's
    /// photos still selected.
    func openPin(_ pin: MapPins.Pin) {
        select(pin.photos)
        guard selection != nil else { return }
        loupe = true
    }
}
