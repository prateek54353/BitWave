import 'package:flutter/material.dart';

abstract final class BitwaveColors {
  static const ink = Color(0xFF08090B);
  static const panel = Color(0xFF111316);
  static const elevated = Color(0xFF191C20);
  static const line = Color(0xFF282C31);
  static const paper = Color(0xFFF2F0E9);
  static const muted = Color(0xFF92969C);
  static const accent = Color(0xFFC29B67);
  static const mint = Color(0xFF9AC7B1);
}

ThemeData bitwaveTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: BitwaveColors.ink,
  colorScheme: const ColorScheme.dark(
    surface: BitwaveColors.ink,
    primary: BitwaveColors.accent,
    secondary: BitwaveColors.mint,
    onSurface: BitwaveColors.paper,
  ),
  fontFamily: 'SpaceGrotesk',
  appBarTheme: const AppBarTheme(
    backgroundColor: BitwaveColors.ink,
    foregroundColor: BitwaveColors.paper,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  sliderTheme: SliderThemeData(
    activeTrackColor: BitwaveColors.accent,
    inactiveTrackColor: BitwaveColors.line,
    thumbColor: BitwaveColors.paper,
    overlayColor: BitwaveColors.accent.withValues(alpha: .16),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: BitwaveColors.elevated,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
);
