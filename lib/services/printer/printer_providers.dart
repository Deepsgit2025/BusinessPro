import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'print_settings.dart';
import 'print_settings_repository.dart';
import 'printer_manager.dart';

/// Single shared repository for the `print_*` / `default_printer_*` settings.
final printSettingsRepoProvider =
    Provider<PrintSettingsRepository>((_) => PrintSettingsRepository());

/// The loaded [PrintSettings] for a business. The detail screen and the settings
/// screen watch this; invalidate it after a `save` to refresh.
final printSettingsProvider =
    FutureProvider.family<PrintSettings, int>((ref, businessId) {
  return ref.watch(printSettingsRepoProvider).load(businessId);
});

/// The single [PrinterManager]. Holds the live connection for the session, so it
/// must be a singleton (not recreated per use).
final printerManagerProvider = Provider<PrinterManager>((ref) {
  return PrinterManager(ref.watch(printSettingsRepoProvider));
});
