import 'package:flutter/material.dart';

/// A raster base layer selectable from the "Map Layers" sheet.
///
/// The list mirrors the layers offered by openstreetmap.org (screenshot 3 in
/// `images_demo`). Every entry is a raster tile template that `flutter_map`
/// can render directly. Layers that need a vendor API key on osm.org
/// (Cycle Map, Transport Map, MapTiler OMT, Tracestrack) are mapped to
/// key-less, OSM-data equivalents here so every row stays usable in the app;
/// [sourceNote] documents the substitution and is shown in the info dialog.
class MapBaseLayer {
  const MapBaseLayer({
    required this.id,
    required this.name,
    required this.urlTemplate,
    this.subdomains = const ['a', 'b', 'c'],
    required this.attribution,
    required this.sourceNote,
    required this.previewSeed,
    this.maxZoom = 19,
    this.needsApiKey = false,
    this.tileWarning,
  });

  final String id;
  final String name;
  final String urlTemplate;
  final List<String> subdomains;
  final String attribution;
  final String sourceNote;
  final Color previewSeed;
  final double maxZoom;
  final bool needsApiKey;
  final String? tileWarning;

  /// The eight rows from the openstreetmap.org layer switcher.
  static const List<MapBaseLayer> osmLayers = [
    MapBaseLayer(
      id: 'standard',
      name: 'Standard',
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      subdomains: [],
      attribution: '© OpenStreetMap contributors',
      sourceNote:
          'The default OSM carto style served from tile.openstreetmap.org. '
          'Usage policy applies; heavy use needs your own tile server.',
      previewSeed: Color(0xFFE8EFE3),
    ),
    MapBaseLayer(
      id: 'cyclosm',
      name: 'CyclOSM',
      urlTemplate:
          'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, CyclOSM',
      sourceNote:
          'Bicycle-oriented render hosted by OSM France. Same data as '
          'openstreetmap.org, styled for cycling (bike lanes, elevation).',
      previewSeed: Color(0xFFE3F0E4),
    ),
    MapBaseLayer(
      id: 'cyclemap',
      name: 'Cycle Map',
      urlTemplate: 'https://{s}.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, OSM France',
      sourceNote:
          'On osm.org this row is Thunderforest OpenCycleMap and needs an API '
          'key. This build substitutes the key-less OSM France style so the '
          'row stays usable.',
      previewSeed: Color(0xFFE9EDF5),
    ),
    MapBaseLayer(
      id: 'transport',
      name: 'Transport Map',
      urlTemplate: 'https://tile.memomaps.de/tilegen/{z}/{x}/{y}.png',
      subdomains: [],
      attribution: '© OpenStreetMap contributors, memomaps.de (ÖPNV)',
      sourceNote:
          'On osm.org this row is Thunderforest Transport and needs an API '
          'key. This build substitutes the key-less public-transport render '
          'from memomaps.de (ÖPNV view) built on the same OSM data.',
      previewSeed: Color(0xFFE7E4F5),
      tileWarning: 'Transport overlay updates slower than Standard.',
    ),
    MapBaseLayer(
      id: 'topo',
      name: 'Tracestrack Topo',
      urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, OpenTopoMap (SRTM)',
      sourceNote:
          'On osm.org this row is Tracetrack Topo. This build substitutes '
          'OpenTopoMap, a key-less topographic render of OSM data with '
          'SRTM hillshading.',
      previewSeed: Color(0xFFEDE8DB),
      maxZoom: 17,
    ),
    MapBaseLayer(
      id: 'humanitarian',
      name: 'Humanitarian',
      urlTemplate: 'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, HOT',
      sourceNote:
          'Humanitarian OSM Team style hosted by OSM France. Designed for '
          'crisis mapping with strong road and place contrast.',
      previewSeed: Color(0xFFF3E8E2),
    ),
    MapBaseLayer(
      id: 'shortbread',
      name: 'Shortbread',
      urlTemplate:
          'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, © CARTO',
      sourceNote:
          'OSM Shortbread itself ships as vector tiles, which this raster '
          'map cannot render. This row substitutes a clean light raster '
          'style (CARTO light) until vector rendering lands.',
      // CARTO's public raster endpoint now rejects unauthenticated requests
      // and returns a flat placeholder tile with "API key required" rendered
      // into the image, so this row is no longer usable without a key.
      needsApiKey: true,
      tileWarning: 'CARTO now requires an API key — tiles render as a blank placeholder.',
      previewSeed: Color(0xFFF1F2F4),
    ),
    MapBaseLayer(
      id: 'omt',
      name: 'MapTiler OMT',
      urlTemplate:
          'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, © CARTO',
      sourceNote:
          'On osm.org this row is MapTiler OMT and needs a MapTiler key. '
          'This build substitutes the key-less CARTO Voyager raster, which '
          'uses the same OpenMapTiles schema family.',
      needsApiKey: true,
      tileWarning: 'CARTO now requires an API key — tiles render as a blank placeholder.',
      previewSeed: Color(0xFFE4EBF3),
    ),
  ];

  /// First layer in [osmLayers] — the reliable, key-less default.
  ///
  /// Anything that depends on CARTO or MapTiler is flagged `needsApiKey` and
  /// must never be the default: those endpoints return a flat placeholder tile
  /// with an "API key required" watermark rather than a tile.
  static const String defaultLayerId = 'standard';

  static MapBaseLayer byId(String id) => osmLayers.firstWhere(
        (l) => l.id == id,
        orElse: () => osmLayers.first,
      );
}

/// Troubleshooting overlays from the bottom of the osm.org switcher.
enum MapOverlay {
  notes('Map Notes', 'Crowd-sourced OSM notes around the current view'),
  data('Map Data', 'Debug tile grid with z/x/y for troubleshooting'),
  traces('Public GPS Traces', 'Public OSM GPS traces raster overlay');

  const MapOverlay(this.title, this.subtitle);
  final String title;
  final String subtitle;
}
