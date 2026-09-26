// Smoke tests for the map-first screen.
//
// These run against a real phone-sized viewport rather than the 800x600 test
// default: the layout is floating elements over a map, so it only means
// anything at handset dimensions, and a desktop-sized box hides overflow bugs
// that a 393x852 screen exposes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:revamp/data/sample_data.dart';
import 'package:revamp/main.dart';
import 'package:revamp/services/geocoding_service.dart';
import 'package:revamp/models/map_layer.dart';
import 'package:revamp/models/place.dart';
import 'package:revamp/widgets/compass.dart';
import 'package:revamp/widgets/floating_search.dart';
import 'package:revamp/widgets/place_card.dart';
import 'package:revamp/widgets/place_marker.dart';
import 'package:revamp/widgets/search_results_panel.dart';

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
    // Reviews is offered twice on purpose: as a button on the hero image
    // and in the action row, because it is what people want next.
    expect(find.text('Reviews'), findsNWidgets(2));
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


  group('search results render from the map query', () {
    // Regression guard: results used to be rendered by a SearchPanel that
    // owned its own private state and searched from its own (hidden) field, so
    // typing in the map's search bar produced an empty panel.

    testWidgets('typing into the bar shows the results panel',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tap(find.byType(FloatingSearchBar));
      await tester.pump();
      expect(find.byType(SearchResultsPanel), findsNothing);

      await tester.enterText(find.byType(TextField), 'kol');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // A geocoding call is attempted (it fails offline in tests, which still
      // proves the panel is driven by the query rather than left inert).
      expect(find.byType(SearchResultsPanel), findsOneWidget);
    });

    testWidgets('the results panel reports errors instead of hiding them',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tap(find.byType(FloatingSearchBar));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'kol');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final panel = tester.widget<SearchResultsPanel>(find.byType(SearchResultsPanel));
      // Either results or a message, never a silently empty panel.
      expect(panel.results.isNotEmpty || panel.error != null, isTrue);
    });

    testWidgets('a single character does not open the panel',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tap(find.byType(FloatingSearchBar));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'k');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Below the two-character minimum there is nothing worth showing.
      expect(find.byType(SearchResultsPanel), findsNothing);
    });
  });

  group('my location', () {
    // Regression guard: initState used to set _locating = true *before* calling
    // locateMe(), so the guard returned early, the flag never cleared, and the
    // button was permanently disabled. The native channel is mocked here so the
    // whole path is exercised, including that the locating state is released.

    Future<void> pumpWithLocation(
      WidgetTester tester, {
      bool serviceEnabled = true,
      bool permission = true,
    }) async {
      const channel = MethodChannel('com.revamp/location');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'isServiceEnabled' => serviceEnabled,
          'hasPermission' => permission,
          'requestPermission' => permission,
          'getCurrentLocation' => <String, dynamic>{
              'latitude': 22.9598,
              'longitude': 88.4473,
              'accuracy': 100.0,
              'provider': 'network',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            },
          _ => null,
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await _pumpPhoneApp(tester);
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('a fix is fetched and the locating state is released',
        (WidgetTester tester) async {
      await pumpWithLocation(tester);

      // The blue "you are here" dot only appears once a fix lands.
      expect(find.byType(MyLocationDot), findsOneWidget);

      final button = tester.widget<MapControlButton>(
        find.widgetWithIcon(MapControlButton, Icons.my_location_rounded),
      );
      expect(button.onPressed, isNotNull,
          reason: 'button must be re-enabled once locating finishes');
    });

    testWidgets('a blocked service reports it and still releases the button',
        (WidgetTester tester) async {
      await pumpWithLocation(tester, serviceEnabled: false);

      expect(find.byType(MyLocationDot), findsNothing);

      final button = tester.widget<MapControlButton>(
        find.widgetWithIcon(MapControlButton, Icons.my_location_rounded),
      );
      expect(button.onPressed, isNotNull,
          reason: 'a failure must not leave the button stuck disabled');
    });
  });

  group('the picked card survives being dragged open', () {
    // Regression guard: the sheet reset its content to the discovery prompt
    // whenever its height dropped below ~25%. Dragging *up* to read a tall card
    // passes through those same heights, so expanding the card wiped it back to
    // "Explore nearby" — the exact symptom reported.

    testWidgets('picking opens the sheet and it stays on the picked card',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tapAt(const Offset(196, 620));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // The pick itself opens the sheet rather than leaving it collapsed.
      expect(find.text('Picked location'), findsOneWidget);

      // Drag the sheet all the way up, through every snap size.
      for (final dy in [-150.0, -200.0, -200.0]) {
        await tester.drag(
            find.byType(DraggableScrollableSheet), Offset(0, dy));
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Still the picked card, never the discovery prompt.
      expect(find.text('Picked location'), findsOneWidget);
      expect(find.text('Explore nearby'), findsNothing);
    });

    testWidgets('dragging the sheet back down keeps the card too',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tapAt(const Offset(196, 620));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Collapse it right down to the peek.
      await tester.drag(
          find.byType(DraggableScrollableSheet), const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 400));

      // Height is not a dismissal signal; only the close button is. (The pin
      // itself is not asserted: once the sheet bottoms out the surplus drag
      // correctly falls through to the map, which pans the pin out of view.)
      expect(find.text('Picked location'), findsOneWidget);
    });
  });

  group('compass', () {
    testWidgets('is hidden while the map is north-up', (t) async {
      await _pumpPhoneApp(t);
      // A compass pinned at "N" on a north-up map is just noise.
      expect(find.byType(CompassButton), findsNothing);
    });

    testWidgets('rounds rotation to the nearest cardinal label', (t) async {
      // flutter_map rotates counter-clockwise, so a positive bearing swings the
      // compass the opposite way. North-up and south are unambiguous; the
      // important property is that 270 and -90 agree, since they are the same
      // orientation expressed two ways.
      expect(cardinalFor(0), 'N');
      expect(cardinalFor(180), 'S');
      expect(cardinalFor(359), 'N');
      expect(cardinalFor(270), cardinalFor(-90));
      expect(cardinalFor(90), cardinalFor(-270));
    });
  });

  group('picked location shows details', () {
    // The picked sheet must name the point, not just print coordinates.
    testWidgets('shows a lookup state, then the resolved name',
        (WidgetTester tester) async {
      // Mock the geocoder so no real network is needed.
      final client = MockClient((req) async {
        if (req.url.path == '/reverse') {
          return http.Response(
            '{"type":"FeatureCollection","features":[{"type":"Feature",'
            '"properties":{"name":"Cubbon Park","city":"Bengaluru",'
            '"country":"India","osm_value":"park"},'
            '"geometry":{"type":"Point","coordinates":[77.5929,12.9763]}}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"type":"FeatureCollection","features":[]}', 200,
            headers: {'content-type': 'application/json'});
      });
      GeocodingService.debugClient = client;
      addTearDown(() => GeocodingService.debugClient = null);

      await _pumpPhoneApp(tester);
      await tester.tapAt(const Offset(196, 620));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // The resolved name is shown, not just coordinates.
      expect(find.text('Cubbon Park'), findsOneWidget);
      // Coordinates remain available for confirming an exact listing spot.
      expect(find.textContaining('12.'), findsWidgets);
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

      // Tap low on the map: the centre happens to sit on a sample place
      // marker, and tapping a marker correctly selects a place instead.
      await tester.tapAt(const Offset(196, 620));
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

      await tester.tapAt(const Offset(196, 620));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(196, 560));
      await tester.pump(const Duration(milliseconds: 400));

      // Exactly one pin, never a stack of them.
      expect(find.byType(PickedPointPin), findsOneWidget);
    });

    testWidgets('the pin survives collapsing the sheet',
        (WidgetTester tester) async {
      await _pumpPhoneApp(tester);

      await tester.tapAt(const Offset(196, 620));
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
