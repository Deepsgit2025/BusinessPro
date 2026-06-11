import 'package:flutter/material.dart';

import 'sync_models.dart';

/// App-level sync feedback. A single global [ScaffoldMessengerState] key lets a
/// sync — manual OR background — pop a bottom snackbar on whatever screen the
/// user is currently on (and even after they navigate away from Sync settings),
/// so a completed sync always confirms itself instead of looking like it stalled.
///
/// The key is attached to the root [MaterialApp] (scaffoldMessengerKey).
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Shows a brief bottom snackbar for a completed sync. [silentWhenNoChange] keeps
/// background ticks quiet when nothing happened (only a manual Sync Now wants the
/// "Already up to date" confirmation).
void showSyncSnack(SyncResult result, {bool silentWhenNoChange = false}) {
  final messenger = rootMessengerKey.currentState;
  if (messenger == null) return;

  final (msg, ok) = _message(result);
  if (msg == null) return; // nothing worth showing
  if (silentWhenNoChange && !result.hasChanges && result.status == SyncStatus.ok) {
    return;
  }

  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(ok ? Icons.cloud_done : Icons.sync_problem,
              color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(msg)),
        ],
      ),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

/// (message, wasSuccess). message null ⇒ show nothing.
(String?, bool) _message(SyncResult r) {
  switch (r.status) {
    case SyncStatus.noInternet:
      return ('No internet — will sync when back online', false);
    case SyncStatus.notLinked:
      return ('Not linked — connect a device to sync', false);
    case SyncStatus.failed:
      return ('Sync failed — will retry automatically', false);
    case SyncStatus.ok:
      if (!r.hasChanges) return ('Already up to date', true);
      final bits = <String>[];
      if (r.inserted > 0) bits.add('${r.inserted} added');
      if (r.updated > 0) bits.add('${r.updated} updated');
      return ('Synced · ${bits.join(', ')}', true);
  }
}
