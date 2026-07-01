import 'package:flutter/widgets.dart';

/// Window-size helpers for the responsive (wide-screen) layouts. These adapt to
/// the actual window width — NOT the platform — so a Windows user who shrinks
/// the window gets the mobile layout back, and Android (always narrow) is never
/// affected. Keep all breakpoint decisions here so they're tuned in one place.
class Responsive {
  Responsive._();

  /// Width at/above which the wide desktop layout (persistent side nav,
  /// master–detail, multi-column forms) kicks in. A maximized or half-screen
  /// Windows window clears this; a phone or a narrow window does not.
  static const double wideBreakpoint = 900;

  /// True when the current window is wide enough for the desktop layout.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;
}
