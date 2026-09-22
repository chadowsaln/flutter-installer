import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'screens/shell.dart';

class FlutterInstallerApp extends StatelessWidget {
  const FlutterInstallerApp({super.key});

  static Future<AppState> createState() async => AppState();

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF02569B);
    return MaterialApp(
      title: 'Flutter Installer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1726),
        cardTheme: const CardThemeData(
          color: Color(0xFF16233A),
          elevation: 0,
          margin: EdgeInsets.all(8),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: const Shell(),
    );
  }
}