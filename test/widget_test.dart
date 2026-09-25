// Smoke test: the app builds and the map widget is present.

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:revamp/main.dart';

void main() {
  testWidgets('Map screen renders a FlutterMap', (WidgetTester tester) async {
    await tester.pumpWidget(const RevMapApp());

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(TileLayer), findsOneWidget);
    expect(find.byType(MarkerLayer), findsOneWidget);
    expect(find.textContaining('OpenStreetMap contributors'), findsOneWidget);
  });
}
