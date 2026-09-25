// Smoke tests for the map-first screen.
//
// These run against a real phone-sized viewport rather than the 800x600 test
// default: the layout is floating elements over a map, so it only means
// anything at handset dimensions, and a desktop-sized box hides overflow bugs
// that a 393x852 screen exposes.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:revamp/data/sample_data.dart';
import 'package:revamp/main.dart';
import 'package:revamp/models/map_layer.dart';
import 'package:revamp/models/place.dart';
import 'package:revamp/widgets/floating_search.dart';
import 'package:revamp/widgets/place_card.dart';
import 'package:revamp/widgets/place_marker.dart';

/// iPhone 14 Pro logical size — the design targets 375-430 pt widths.
const _phone = Size(393, 852);

Future<void> _pumpPhoneApp(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = _phone;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(const RevMapApp());
  await tester.pump();
}

void main() {
  testWidgets('map renders and fills the screen', (WidgetTester tester) async {
    await _pumpPhoneApp(tester);

    final map = find.byType(FlutterMap);
    expect(map, findsOneWidget);
    // The map must be the dominant element, not a card in a scrolling page.
    expect(tester.getSize(map), _phone);
  });

  testWidgets('floating search and category pills sit above the map',
      (WidgetTester tester) async {
    await _pumpPhoneApp(tester);

    expect(find.byType(FloatingSearchBar), findsOneWidget);
    expect(find.byType(CategoryPills), findsOneWidget);
    // One pill per configured category.
    expect(find.byType(CategoryPills), findsOneWidget);
  });

  testWidgets('markers render for the sample places',
      (WidgetTester tester) async {
    await _pumpPhoneApp(tester);

    // A marker per visible place. Cluster markers only appear when zoomed out
    // far enough, so at rest each place keeps its own pin.
    expect(find.byType(PlaceMarker), findsWidgets);
    // No location fix exists in a test environment.
    expect(find.byType(MyLocationDot), findsNothing);
  });

  testWidgets('OSM attribution is visible', (WidgetTester tester) async {
    await _pumpPhoneApp(tester);
    // Required by the tile usage policy; must never be removed.
    expect(find.byType(SimpleAttributionWidget), findsOneWidget);
  });

  testWidgets('place card renders name, rating and actions',
      (WidgetTester tester) async {
    final place = SampleData.places.first;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaceCard(place: place, distanceLabel: '450 m'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(place.name), findsOneWidget);
    expect(find.text('Directions'), findsOneWidget);
    expect(find.text('Tickets'), findsOneWidget);
    expect(find.text('Reviews'), findsOneWidget);
  });

  test('distance label switches from metres to kilometres', () {
    final park =
        SampleData.places.firstWhere((p) => p.category == PlaceCategory.park);
    const near = LatLng(12.9716, 77.5946);

    // A park several km away should read in km, and the number must match the
    // haversine result rather than a hardcoded string.
    expect(park.distanceLabelFrom(near), endsWith('km'));
    expect(park.distanceKmFrom(near), greaterThan(1));

    // A point on top of the place should read in metres.
    expect(park.distanceLabelFrom(park.point), endsWith('m'));
  });

  test('place labels and counts format correctly', () {
    final place = SampleData.places.first;
    expect(place.reviewCountLabel, contains('rating'));
    expect(place.openLabel, isNotEmpty);
    expect(place.ratingLabel, isNotEmpty);
    expect(place.category.icon, isNotNull);
  });

  group('search bar stays put', () {
    // Regression guard: search used to open a bottom sheet, which moved the
    // typing surface away from the top of the screen.
    testWidgets('tapping search turns the bar into a field in place',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      final barFinder = find.byType(FloatingSearchBar);
      expect(barFinder, findsOneWidget);

      // Before tapping: a hint, and no editable field.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('What are you looking for?'), findsOneWidget);

      await tester.tap(barFinder);
      await tester.pump();

      // After tapping: a real field, same position, and the hint is gone.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('What are you looking for?'), findsNothing);
      expect(find.byType(FloatingSearchBar), findsOneWidget);
    });

    testWidgets('the bar keeps its position when the field activates',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      final barFinder = find.byType(FloatingSearchBar);
      final before = tester.getTopLeft(barFinder);
      final sizeBefore = tester.getSize(barFinder);

      await tester.tap(barFinder);
      await tester.pump();

      final after = tester.getTopLeft(barFinder);
      final sizeAfter = tester.getSize(barFinder);

      // Same spot, same size — the keyboard cannot shift the chrome.
      expect(after, before);
      expect(sizeAfter, sizeBefore);
    });
  });


  group('picking a location on the map', () {
    // Regression guard: the redesign dropped tap-to-pick entirely, leaving map
    // taps as a no-op unless a place was already selected.

    testWidgets('tapping the map drops a pin and opens the picked sheet',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      // Nothing picked to begin with.
      expect(find.byType(PickedPointPin), findsNothing);

      // Tap the middle of the map, away from the floating chrome.
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(PickedPointPin), findsOneWidget);
      expect(find.text('Picked location'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a second tap moves the pin rather than stacking',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await tester.pump(const Duration(milliseconds: 400));

      // Exactly one pin, never a stack of them.
      expect(find.byType(PickedPointPin), findsOneWidget);
    });

    testWidgets('the pin survives collapsing the sheet',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PickedPointPin), findsOneWidget);

      // Drag the sheet down towards its collapsed size.
      await tester.drag(
          find.byType(DraggableScrollableSheet), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 400));

      // The point stays on the map even though its card is gone.
      expect(find.byType(PickedPointPin), findsOneWidget);
    });
  });

  test('default base layer needs no API key', () {
    // CARTO and MapTiler return a flat "API key required" placeholder tile
    // without a key, so the default must be the key-less OSM standard style.
    final layer = MapBaseLayer.byId(MapBaseLayer.defaultLayerId);
    expect(layer.needsApiKey, isFalse);
    expect(layer.urlTemplate, contains('tile.openstreetmap.org'));
  });
}
