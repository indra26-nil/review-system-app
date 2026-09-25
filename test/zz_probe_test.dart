import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:revamp/main.dart';

void main() {
  testWidgets('hit path at y=500', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    await tester.pumpWidget(const RevMapApp());
    await tester.pump(const Duration(milliseconds: 200));
    for (final y in [300.0, 500.0, 700.0]) {
      final res = tester.hitTestOnBinding(Offset(196, y));
      final types = res.path.map((e) => e.target.runtimeType.toString()).toList();
      debugPrint('y=$y PATH: ${types.take(6).join(" > ")}');
      // Show the nearest FlutterMap in the path
      debugPrint('     hasFlutterMap=${types.any((t) => t.contains("MobileLayer") || t.contains("FlutterMap") || t.contains("Tile"))}');
    }
  });
}
