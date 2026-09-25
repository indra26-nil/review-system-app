import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:revamp/main.dart';
import 'package:revamp/widgets/place_marker.dart';

void main() {
  testWidgets('y=426 selects a place instead of dropping a pin', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(393, 852);
    addTearDown(() { t.view.resetPhysicalSize(); t.view.resetDevicePixelRatio(); });
    await t.pumpWidget(const RevMapApp());
    await t.pump(const Duration(milliseconds: 200));
    debugPrint('markers on screen: ${find.byType(PlaceMarker).evaluate().length}');
    // Is there a marker right at (196,426)?
    final hit = t.hitTestOnBinding(const Offset(196, 426));
    debugPrint('hit top: ${hit.path.first.target.runtimeType}');
    await t.tapAt(const Offset(196, 426));
    await t.pump(const Duration(milliseconds: 500));
    debugPrint('after tap: pin=${find.byType(PickedPointPin).evaluate().length}');
  });
}
