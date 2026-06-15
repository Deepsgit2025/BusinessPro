import 'package:flutter/material.dart';

import '../../screens/security/app_lock_screen.dart';
import '../../services/security/app_lock_service.dart';

/// Wraps the app so the lock screen can appear on top of the live UI without
/// tearing it down.
///
/// The [child] (the real app) stays mounted in a [Stack] at all times; when
/// [AppLockService.isLocked] is true an [AppLockScreen] is painted over it.
/// This means returning from the lock screen lands the user exactly where they
/// were. Lifecycle changes are forwarded to the service so it can auto-lock.
class AppLockWrapper extends StatefulWidget {
  final Widget child;
  const AppLockWrapper({super.key, required this.child});

  @override
  State<AppLockWrapper> createState() => _AppLockWrapperState();
}

class _AppLockWrapperState extends State<AppLockWrapper>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final service = AppLockService.instance;
    switch (state) {
      case AppLifecycleState.resumed:
        service.onAppResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        service.onAppPaused();
      case AppLifecycleState.detached:
        service.onAppDetached();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLockService.instance,
      builder: (context, _) {
        final locked = AppLockService.instance.isLocked;
        return Stack(
          children: [
            widget.child,
            if (locked)
              const Positioned.fill(
                child: AppLockScreen(),
              ),
          ],
        );
      },
    );
  }
}
