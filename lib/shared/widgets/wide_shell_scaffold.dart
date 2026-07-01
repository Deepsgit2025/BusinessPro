import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/utils/responsive.dart';
import 'side_nav_rail.dart';

/// Wraps a pushed full-screen page so that, on a WIDE (Windows/desktop) window,
/// the persistent left navigation rail stays visible beside the page — matching
/// the shell. On a narrow window it returns [child] unchanged (the page is
/// full-width as before).
///
/// Because a pushed page sits above the [MainShell], the rail here can't drive
/// the shell's IndexedStack directly. Instead, tapping a primary destination
/// pops back to the shell (root) so the user lands back in the app's main
/// navigation; secondary destinations push their own routes (handled inside
/// [SideNavRail]). [selectedIndex] is just for highlighting (defaults to none).
class WideShellScaffold extends StatelessWidget {
  final Widget child;

  /// Which primary destination to highlight in the rail, or -1 for none (e.g.
  /// the sale form isn't itself one of the four primary tabs).
  final int selectedIndex;

  const WideShellScaffold({
    super.key,
    required this.child,
    this.selectedIndex = -1,
  });

  @override
  Widget build(BuildContext context) {
    if (!Responsive.isWide(context)) return child;

    return Row(
      children: [
        SideNavRail(
          selectedIndex: selectedIndex,
          // From a pushed page, a primary destination returns to the shell.
          // Pop back to root so the main navigation (and its tabs) is shown.
          onSelect: (_) =>
              Navigator.of(context).popUntil((route) => route.isFirst),
        ),
        VerticalDivider(
            width: 1, thickness: 1, color: AppColors.dividerOf(context)),
        Expanded(child: child),
      ],
    );
  }
}
