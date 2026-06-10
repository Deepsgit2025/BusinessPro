import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const primary = Color(0xFF1B7A3D);       // Refined emerald green
  static const primaryLight = Color(0xFF4CAF50);  // Medium green
  static const primaryDark = Color(0xFF0E5A2A);   // Dark green
  static const accent = Color(0xFF00C853);         // Bright green accent

  static const income = Color(0xFF1B7A3D);
  static const expense = Color(0xFFE53935);
  static const pending = Color(0xFFF57F17);
  static const paid = Color(0xFF1B7A3D);
  static const partial = Color(0xFF1565C0);

  static const surfaceLight = Colors.white;
  static const backgroundLight = Color(0xFFF2F5F3);
  static const cardLight = Colors.white;

  static const surfaceDark = Color(0xFF1E1E1E);
  static const backgroundDark = Color(0xFF101512);
  static const cardDark = Color(0xFF1C2420);

  static const textPrimary = Color(0xFF1A2420);
  static const textSecondary = Color(0xFF6B7770);
  static const textHint = Color(0xFFAEB8B2);

  static const divider = Color(0xFFEAEEEC);
  static const border = Color(0xFFE0E5E2);

  // Gradients used for headers, hero cards and the brand accents.
  static const brandGradient = LinearGradient(
    colors: [primaryDark, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const incomeGradient = LinearGradient(
    colors: [Color(0xFF1B7A3D), Color(0xFF34A853)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const expenseGradient = LinearGradient(
    colors: [Color(0xFFE53935), Color(0xFFFF6F60)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Theme-aware helpers ────────────────────────────────────────────────────
  // The colour constants above are baked light-mode values. Screens that paint
  // their own surfaces (Sale/Purchase grids, the transaction entry forms) must
  // use these context-aware getters instead of the raw constants so they flip
  // correctly under dark mode. Each returns the dark variant when the active
  // theme is dark, otherwise the original light value.

  static bool _isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// Primary card / panel surface (was a hardcoded `Colors.white`).
  static Color surface(BuildContext c) => _isDark(c) ? cardDark : surfaceLight;

  /// App scaffold background (was `AppColors.backgroundLight`). Also the right
  /// colour for the thick section-divider bars between form blocks.
  static Color background(BuildContext c) =>
      _isDark(c) ? backgroundDark : backgroundLight;

  /// High-emphasis body text (was `AppColors.textPrimary`).
  static Color textPrimaryOf(BuildContext c) =>
      _isDark(c) ? const Color(0xFFE8EDEA) : textPrimary;

  /// Hairline divider / field border (was `AppColors.divider` / `border`).
  static Color dividerOf(BuildContext c) =>
      _isDark(c) ? const Color(0x1FFFFFFF) : divider;

  /// Foreground that sits on top of a coloured surface and must stay legible in
  /// either theme — i.e. the equivalent of the old `Colors.white` content
  /// colour. In dark mode white still reads fine, so this is mostly a semantic
  /// marker, but kept as a helper for symmetry.
  static Color onSurface(BuildContext c) => textPrimaryOf(c);
}
