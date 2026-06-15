import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // ── Brand (purple) ─────────────────────────────────────────────────────────
  // The app skin: app bars, buttons, FAB, nav highlight, focus rings, brand
  // gradients. Changing these repaints the whole app (every screen reads these
  // semantic constants, not raw hex).
  static const primary = Color(0xFF6A1B9A);       // Deep purple
  static const primaryLight = Color(0xFF9C4DCC);  // Lighter purple (dark mode)
  static const primaryDark = Color(0xFF4A148C);   // Dark purple (gradients)
  static const accent = Color(0xFFB388FF);         // Violet pop / secondary

  // ── Money semantics (kept conventional — NOT part of the rebrand) ───────────
  // Positive money is green, expense red, pending amber. These have their own
  // literals so the purple rebrand never sweeps them up.
  static const income = Color(0xFF1B7A3D);   // green — money in
  static const expense = Color(0xFFE53935);  // red — money out
  static const pending = Color(0xFFF57F17);  // amber — outstanding
  static const paid = Color(0xFF1B7A3D);     // green — settled
  static const partial = Color(0xFF1565C0);  // blue — part-paid

  static const surfaceLight = Colors.white;
  // Faint cool tint so white cards lift off the page (subtle depth).
  static const backgroundLight = Color(0xFFF5F3F8);
  static const cardLight = Colors.white;

  // Cool near-black surfaces so purple reads as the accent in dark mode.
  static const surfaceDark = Color(0xFF1B1726);
  static const backgroundDark = Color(0xFF12101A);
  static const cardDark = Color(0xFF1B1726);

  static const textPrimary = Color(0xFF1C1726);
  static const textSecondary = Color(0xFF6E6880);
  static const textHint = Color(0xFFB1ACBE);

  static const divider = Color(0xFFEDEAF2);
  static const border = Color(0xFFE3DFEC);

  // Gradients used for headers, hero cards and the brand accents.
  static const brandGradient = LinearGradient(
    colors: [primaryDark, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Richer 3-stop brand gradient for hero surfaces (dashboard, headers).
  static const heroGradient = LinearGradient(
    colors: [primaryDark, primary, accent],
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
      _isDark(c) ? const Color(0xFFEDEAF5) : textPrimary;

  /// Hairline divider / field border (was `AppColors.divider` / `border`).
  static Color dividerOf(BuildContext c) =>
      _isDark(c) ? const Color(0x1FFFFFFF) : divider;

  /// Foreground that sits on top of a coloured surface and must stay legible in
  /// either theme — i.e. the equivalent of the old `Colors.white` content
  /// colour. In dark mode white still reads fine, so this is mostly a semantic
  /// marker, but kept as a helper for symmetry.
  static Color onSurface(BuildContext c) => textPrimaryOf(c);
}
