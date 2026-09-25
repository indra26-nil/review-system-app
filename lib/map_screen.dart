import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A demo place, so there is something visible on the map while the real
/// database layer is not wired up yet.
class DemoPlace {
  const DemoPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  LatLng get point => LatLng(latitude, longitude);
}

/// Minimal map screen: OpenStreetMap raster tiles + tappable markers.
///
/// Tiles come from the free, key-less OSM public server, so no API key and no
/// billing account is required. The `userAgentPackageName` is a stable,
/// app-specific identifier that OSM asks every app to send; the attribution
/// widget below is required to stay on screen.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  // Somewhere to land on first launch. Change this to any city.
  static const LatLng _initialCenter = LatLng(12.9716, 77.5946); // Bengaluru
  static const double _initialZoom = 13;

  static const String _tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _userAgentPackageName = 'com.revmap.revamp';

  // Later this list comes from RevMap's own backend instead of being hardcoded.
  static const List<DemoPlace> _places = [
    DemoPlace(id: '1', name: 'Sample Store', latitude: 12.9716, longitude: 77.5946),
    DemoPlace(id: '2', name: 'Corner Cafe', latitude: 12.9784, longitude: 77.6408),
    DemoPlace(id: '3', name: 'City Market', latitude: 12.9698, longitude: 77.5750),
  ];

  /// Point picked by the last map tap, shown as a draggable pin.
  LatLng? _pickedPoint;
  DemoPlace? _selectedPlace;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RevMap')),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _initialCenter,
          initialZoom: _initialZoom,
          minZoom: 2,
          maxZoom: 19,
          backgroundColor: const Color(0xFFE8E3DC),
          onTap: (_, point) => setState(() {
            _pickedPoint = point;
            _selectedPlace = null;
          }),
        ),
        children: [
          TileLayer(
            urlTemplate: _tileUrlTemplate,
            userAgentPackageName: _userAgentPackageName,
          ),
          MarkerLayer(
            markers: [
              for (final place in _places)
                Marker(
                  key: ValueKey(place.id),
                  point: place.point,
                  width: 44,
                  height: 44,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _selectedPlace = place;
                      _pickedPoint = null;
                    }),
                    child: _PlacePin(isSelected: place == _selectedPlace),
                  ),
                ),
              if (_pickedPoint != null)
                Marker(
                  point: _pickedPoint!,
                  width: 44,
                  height: 44,
                  child: const _PlacePin(isSelected: true),
                ),
            ],
          ),
          SimpleAttributionWidget(
            source: const Text('OpenStreetMap contributors'),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'zoom_in',
            tooltip: 'Zoom in',
            onPressed: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom + 1,
            ),
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'zoom_out',
            tooltip: 'Zoom out',
            onPressed: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom - 1,
            ),
            child: const Icon(Icons.remove),
          ),
        ],
      ),
      bottomNavigationBar: _StatusBar(
        selectedPlace: _selectedPlace,
        pickedPoint: _pickedPoint,
      ),
    );
  }
}

class _PlacePin extends StatelessWidget {
  const _PlacePin({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? Colors.deepPurple : Colors.redAccent;
    return Icon(Icons.storefront, color: color, size: isSelected ? 36 : 30);
  }
}

/// Shows either the tapped place or the coordinates picked for a new listing.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.selectedPlace, required this.pickedPoint});

  final DemoPlace? selectedPlace;
  final LatLng? pickedPoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String message;
    if (selectedPlace != null) {
      message = '${selectedPlace!.name}  •  '
          '${selectedPlace!.latitude.toStringAsFixed(5)}, '
          '${selectedPlace!.longitude.toStringAsFixed(5)}';
    } else if (pickedPoint != null) {
      message = 'New place at '
          '${pickedPoint!.latitude.toStringAsFixed(5)}, '
          '${pickedPoint!.longitude.toStringAsFixed(5)}';
    } else {
      message = 'Tap the map to pick a location, tap a pin for details';
    }

    return SafeArea(
      child: Container(
        width: double.infinity,
        color: theme.colorScheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Text(message, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
