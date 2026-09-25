import 'package:flutter/material.dart';

/// How a journey is mainly travelled.
///
/// Each mode carries its own icon and tint so the mode selector and the route
/// timeline read as one family. The tints stay low-saturation on purpose:
/// several of them can share one screen and the sheet should still feel calm,
/// the same restraint that keeps place markers from turning the map into
/// confetti.
enum TransportMode {
  train('Train', Icons.train_rounded, Color(0xFF3B6FC4)),
  walking('Walking', Icons.directions_walk_rounded, Color(0xFF4E8C63)),
  bicycle('Bicycle', Icons.pedal_bike_rounded, Color(0xFF9A6B4F)),
  bus('Bus', Icons.directions_bus_rounded, Color(0xFFB07C3A));

  const TransportMode(this.label, this.icon, this.tint);

  /// The name on the pill. Kept singular because it names a way of travelling,
  /// not a count of vehicles.
  final String label;

  /// A rounded icon so it sits optically level with the app's other icons.
  final IconData icon;

  /// Fill for badges, timeline nodes and the pill icon when unselected.
  final Color tint;
}

/// The kind of movement a single leg describes.
///
/// A leg is the smallest unit the timeline understands: "walk to the metro",
/// "take the Purple Line", "ride three stops".
enum RouteLegType { walk, train, bus, bicycle }

/// One leg of a route: a single movement with one line, one duration.
class RouteLeg {
  const RouteLeg({
    required this.type,
    this.lineLabel,
    required this.durationMinutes,
    this.stops,
    this.instruction,
    this.stopName,
  });

  final RouteLegType type;

  /// e.g. "52" or "Purple" — rendered as a small compact rounded badge rather
  /// than an icon, because a line number is the thing people actually read.
  final String? lineLabel;

  /// How long this leg takes. Whole minutes: routing granularity is coarse and
  /// a fake-seconds number reads as noise.
  final int durationMinutes;

  /// Intermediate stops, e.g. 5. Null when the leg has no stops to count.
  final int? stops;

  /// e.g. "Walk to MG Road Metro" — the imperative hint shown on the timeline.
  final String? instruction;

  /// Where this leg lands, e.g. "MG Road Metro".
  final String? stopName;

  /// The mode this leg belongs to, so the timeline can reuse the mode's icon
  /// and tint instead of defining a second, parallel set.
  TransportMode get mode => switch (type) {
        RouteLegType.walk => TransportMode.walking,
        RouteLegType.bicycle => TransportMode.bicycle,
        RouteLegType.train => TransportMode.train,
        RouteLegType.bus => TransportMode.bus,
      };

  /// The leg's tint, taken from its mode.
  Color get tint => mode.tint;

  /// "Line 52" / "Bus 52A" / "Walk" — one short phrase naming the leg, for
  /// places where there is no room for a full instruction.
  String get legLabel {
    final line = lineLabel;
    final named = (line == null || line.isEmpty) ? null : line;
    return switch (type) {
      RouteLegType.walk => 'Walk',
      RouteLegType.bicycle => 'Cycle',
      RouteLegType.train => named == null ? 'Metro' : 'Line $named',
      RouteLegType.bus => named == null ? 'Bus' : 'Bus $named',
    };
  }

  /// "9 min" — the duration on its own.
  String get durationLabel => '$durationMinutes min';

  /// "9 min · 3 stops" — the grey secondary line under a timeline step.
  String get metadataLabel {
    final buffer = StringBuffer(durationLabel);
    final s = stops;
    if (s != null && s > 0) {
      buffer.write(' · $s ${s == 1 ? 'stop' : 'stops'}');
    }
    return buffer.toString();
  }
}

/// A whole origin-to-destination journey.
///
/// Deliberately flat and pre-computed: the route list, the detail header and
/// the timeline all read the same fields, so the numbers can never disagree
/// between the row a rider scans and the sheet they open.
class TransportRoute {
  const TransportRoute({
    required this.id,
    required this.mode,
    required this.durationMinutes,
    required this.priceLabel,
    required this.distanceKm,
    required this.legs,
    this.isFastest = false,
    this.arrivalLabel,
  });

  final String id;

  /// The mode that dominates this route; decides the icon and tint used for it.
  final TransportMode mode;

  final int durationMinutes;

  /// Already formatted by the data source, e.g. "₹2.99" or "$2.99". The sheet
  /// must not re-format money: currencies and rounding rules belong upstream.
  final String priceLabel;

  final double distanceKm;

  /// Ordered from departure to arrival. The timeline and the badges both walk
  /// this list in order.
  final List<RouteLeg> legs;

  /// Marks the quickest option, which earns a small "Fastest" pill.
  final bool isFastest;

  /// e.g. "Arrive 14:32" — quieter than the duration, but the reason people
  /// pick a route over a quicker one.
  final String? arrivalLabel;

  /// "17 min" — the loudest number in the row, so it stays a plain integer.
  String get durationLabel => '$durationMinutes min';

  /// "850 m" under a kilometre, otherwise "4.2 km".
  String get distanceLabel => _distanceLabel(distanceKm);

  /// "8 min walk" / "No walking" — the small line under the duration.
  String get walkLabel =>
      walkMinutes > 0 ? '$walkMinutes min walk' : 'No walking';

  /// The line badges worth showing, e.g. ["52", "40"].
  ///
  /// Walk legs are skipped: a badge with no line number would just be noise.
  List<String> get lineLabels => [
        for (final leg in legs)
          if ((leg.lineLabel ?? '').isNotEmpty) leg.lineLabel!,
      ];

  /// Total minutes spent walking across every leg, which is what the small
  /// walk figure in the row reports.
  int get walkMinutes => legs
      .where((leg) => leg.type == RouteLegType.walk)
      .fold(0, (total, leg) => total + leg.durationMinutes);

  /// A short human read of the legs, e.g. "4 min walk → Line 52 → Line 40".
  /// Used for accessibility labels and the detail header.
  String get summary {
    final parts = <String>[
      for (final leg in legs)
        switch (leg.type) {
          RouteLegType.walk => '${leg.durationMinutes} min walk',
          RouteLegType.bicycle => '${leg.durationMinutes} min cycle',
          _ => leg.legLabel,
        },
    ];
    return parts.isEmpty ? 'Direct' : parts.join(' → ');
  }
}

/// The three numbers the route detail header leads with.
///
/// A tiny value object so the header can be built and previewed from plain
/// numbers, without the header having to know how a route is assembled.
class TransportRouteDetails {
  const TransportRouteDetails({
    required this.durationMinutes,
    required this.distanceKm,
    required this.priceLabel,
  });

  /// Lift the headline numbers off a [TransportRoute].
  factory TransportRouteDetails.from(TransportRoute r) => TransportRouteDetails(
        durationMinutes: r.durationMinutes,
        distanceKm: r.distanceKm,
        priceLabel: r.priceLabel,
      );

  final int durationMinutes;
  final double distanceKm;
  final String priceLabel;

  /// "17 min" — mirrors the row exactly, so the number reads identically in
  /// both places and a rider does not have to re-learn it.
  String get durationLabel => '$durationMinutes min';

  /// "850 m" under a kilometre, otherwise "4.2 km".
  String get distanceLabel => _distanceLabel(distanceKm);
}

/// The app's one distance format, shared so a route and its detail header can
/// never disagree about how far something is.
String _distanceLabel(double km) {
  final m = km * 1000;
  if (m < 950) return '${m.round()} m';
  return '${km.toStringAsFixed(1)} km';
}
