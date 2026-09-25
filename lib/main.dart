import 'package:flutter/material.dart';

import 'map_screen.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}
