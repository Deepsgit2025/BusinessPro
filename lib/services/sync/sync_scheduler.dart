import 'dart:async';

import 'sync_models.dart';

/// Decides *when* a sync runs and guarantees it runs silently and serially.
///
/// Triggers (per the Phase 5 spec): app resume, ~3s after a transaction is
/// saved, every 15 minutes while the app is open, and an explicit manual button.
/// All but the manual path are fire-and-forget and swallow errors — a sync must
/// never interrupt or crash the app.
///
/// The scheduler owns no Drive/Auth state itself; it calls [runSync], a callback
/// the composition root wires to the live [SyncEngine.sync] (or to a no-op while
/// the device isn't linked).
class SyncScheduler {
  /// Runs one sync and returns its result. Supplied by the provider layer so the
  /// scheduler stays decoupled from how the engine is built.
  final Future<SyncResult> Function() runSync;

  /// Called after any sync that changed local data, so the UI (bell badge,
  /// lists) can refresh. Optional.
  final void Function(SyncResult result)? onChanged;

  SyncScheduler({required this.runSync, this.onChanged});

  Timer? _periodicTimer;
  Timer? _debounceTimer;
  bool _running = false;

  static const _periodicInterval = Duration(minutes: 15);
  static const _postTransactionDelay = Duration(seconds: 3);

  /// Starts the 15-minute background tick. Safe to call more than once.
  void startPeriodicSync() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      _runSilent();
    });
  }

  /// Sync when the app returns to the foreground.
  void onAppResume() => _runSilent();

  /// Sync shortly after a transaction is saved. Debounced so rapid successive
  /// saves (e.g. quick multi-bill entry) collapse into a single run once the
  /// user pauses.
  void onTransactionSaved() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_postTransactionDelay, _runSilent);
  }

  /// The manual "Sync Now" path — returns the result so the UI can show it.
  /// Still guarded against overlap with a background run.
  Future<SyncResult> onManualSync() => _run();

  /// Fire-and-forget background sync. Never throws.
  void _runSilent() {
    _run().catchError((_) => SyncResult.failed());
  }

  /// Runs a sync unless one is already in flight (prevents overlapping uploads
  /// of the same changes file).
  Future<SyncResult> _run() async {
    if (_running) return const SyncResult();
    _running = true;
    try {
      final result = await runSync();
      if (result.didSomething) onChanged?.call(result);
      return result;
    } catch (_) {
      return SyncResult.failed();
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _periodicTimer?.cancel();
    _debounceTimer?.cancel();
  }
}
