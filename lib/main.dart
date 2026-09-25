import 'package:flutter/material.dart';

import 'map_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const RevMapApp());
}

class RevMapApp extends StatelessWidget {
  const RevMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RevMap',
      debugShowCheckedModeBanner: false,
      theme: RevMapTheme.light(),
      home: const MapScreen(),
    );
  }
}
