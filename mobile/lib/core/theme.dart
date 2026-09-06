/// Avertis visual language.
///
/// Designed for the actual conditions of use: outdoors, one-handed, possibly
/// in poor light, by someone under stress. High contrast, large touch targets,
/// and priority communicated by colour *and* text — never colour alone.
library;

import 'package:flutter/material.dart';

class AvertisColors {
  static const background = Color(0xFF0B0F14);
  static const surface = Color(0xFF151B23);
  static const surfaceHigh = Color(0xFF1E2733);
  static const outline = Color(0xFF2C3846);

  static const lifeCritical = Color(0xFFFF4438);
  static const emergency = Color(0xFFFF8A3D);
  static const operational = Color(0xFFFFC53D);
  static const normal = Color(0xFF6B7785);

  static const online = Color(0xFF35D07F);
  static const offline = Color(0xFFFF4438);
  static const mesh = Color(0xFF3DA5FF);

  static const textPrimary = Color(0xFFF2F5F8);
  static const textSecondary = Color(0xFF9AA7B5);
}

ThemeData buildAvertisTheme() {
  const scheme = ColorScheme.dark(
    primary: AvertisColors.mesh,
    surface: AvertisColors.surface,
    error: AvertisColors.lifeCritical,
    onPrimary: Colors.white,
    onSurface: AvertisColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AvertisColors.background,
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: AvertisColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AvertisColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    ),
    cardTheme: CardThemeData(
      color: AvertisColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AvertisColors.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(60),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AvertisColors.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AvertisColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AvertisColors.outline),
      ),
    ),
  );
}

/// Priority colour. Always paired with the priority's text label in the UI —
/// colour alone is not an accessible signal.
Color colorForPriority(String priority) => switch (priority) {
      'LIFE_CRITICAL' => AvertisColors.lifeCritical,
      'EMERGENCY' => AvertisColors.emergency,
      'OPERATIONAL' => AvertisColors.operational,
      _ => AvertisColors.normal,
    };
