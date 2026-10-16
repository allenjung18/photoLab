import SwiftUI
import MapKit

/// The map (View › Map, ⌥⌘M): the visible photos that carry a GPS position
/// (`PhotoLocations`), bucketed into pins by `MapPins.group` at a cell size
/// taken from the visible span, so zooming in splits a pin and zooming out
/// merges pins. The tiles are Apple's, over the network (MapKit; no key, no
/// entitlement): offline the pins draw on a blank grid. A click on a pin
/// selects its photos (`Library.clickPin`), a double-click opens the first
/// in the loupe (`Library.openPin`). The camera frames every pin
/// (`MapPins.region(fitting:)`) when the map opens and again when the
/// location pass finishes.
struct PhotoMapView: View {
    @Environment(Library.self) private var library
    @State private var position: MapCameraPosition = .automatic
    /// The visible span after the last camera move; nil until the map
    /// reports one.
    @State private var span: MKCoordinateSpan?

    var body: some View {
        let visible = library.visiblePhotos
        let located = library.locations.located(in: visible)
        let reading = library.locations.reading
        Group {
            if located.isEmpty, reading == nil {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(visible.isEmpty ? "No photos to place" : "None of these photos has a location")
                        .font(.title3)
                    Text("A photo shows on the map when its camera or phone recorded where it was taken.")
                        .foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                map(located)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(located: located.count, of: visible.count, reading: reading)
        }
        .onAppear { frame(located) }
        .onChange(of: reading == nil) { _, finished in
            if finished { frame(library.locations.located(in: library.visiblePhotos)) }
        }
    }

    private func map(_ located: [LocatedPhoto]) -> some View {
        let shownSpan = span ?? MapPins.region(fitting: located.map(\.point))?.span
        let cell = MapPins.cellDegrees(latitudeDelta: shownSpan?.latitudeDelta ?? 1,
                                       longitudeDelta: shownSpan?.longitudeDelta ?? 1)
        let pins = MapPins.group(located, cellDegrees: cell)
        return Map(position: $position) {
            ForEach(pins) { pin in
                Annotation(pin.count == 1 ? library.name(for: pin.first) : "\(pin.count) photos",
                           coordinate: pin.coordinate.coordinate, anchor: .bottom) {
                    MapPinLabel(pin: pin, selected: pin.photos.contains { library.selectedIDs.contains($0) },
                                recipe: library.recipe(for: pin.first))
                        .onTapGesture(count: 2) { library.openPin(pin) }
                        .onTapGesture { library.clickPin(pin) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            span = context.region.span
        }
    }

    private func footer(located: Int, of total: Int, reading: (done: Int, total: Int)?) -> some View {
        HStack(spacing: 8) {
            if let reading {
                ProgressView().controlSize(.small)
                Text("Reading locations \(reading.done) of \(reading.total)")
            } else {
                Text(PhotoLocations.summary(located: located, of: total))
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func frame(_ located: [LocatedPhoto]) {
        guard let region = MapPins.region(fitting: located.map(\.point)) else { return }
        span = region.span
        position = .region(region)
    }
}

/// One pin: the first photo's thumbnail (its edit shown, as in the grid) in
/// a rounded frame, the count in a badge when the pin holds more than one,
/// an accent border when any of its photos is selected.
private struct MapPinLabel: View {
    let pin: MapPins.Pin
    let selected: Bool
    let recipe: Recipe
    @State private var image: NSImage?

    private struct Load: Equatable {
        let id: Photo.ID
        let recipe: Recipe
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.white, lineWidth: selected ? 3 : 2))
        .shadow(radius: 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if pin.count > 1 {
                Text("\(pin.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 8, y: -8)
            }
        }
        .contentShape(Rectangle())
        .help(pin.count == 1 ? "Click to select, double-click to open"
                             : "\(pin.count) photos: click to select them, double-click to open the first")
        .task(id: Load(id: pin.first, recipe: recipe)) {
            image = await Thumbnails.shared.thumbnail(for: pin.first, recipe: recipe)
        }
    }
}
