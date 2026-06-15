import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/constants/app_strings.dart';
import 'firebase_options.dart';
import 'core/constants/app_theme.dart';
import 'core/database/database_helper.dart';
import 'core/providers/theme_provider.dart';
import 'features/cash_bank/screens/accounts_list_screen.dart';
import 'features/company/screens/company_setup_screen.dart';
import 'features/expense/screens/expense_list_screen.dart';
import 'features/income/screens/income_list_screen.dart';
import 'features/employees/screens/employees_list_screen.dart';
import 'features/backup/screens/backup_screen.dart';
import 'features/inventory/screens/inventory_list_screen.dart';
import 'features/items/screens/items_list_screen.dart';
import 'features/reports/screens/reports_home_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/sync/screens/sync_settings_screen.dart';
import 'services/security/app_lock_service.dart';
import 'services/sync/sync_feedback.dart';
import 'shared/widgets/main_shell.dart';
import 'widgets/security/app_lock_wrapper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize DB — creates all tables + seeds data on first run
  await DatabaseHelper.database;

  // Phase 6 Layer 1: load the optional PIN-lock state before the first frame so
  // a protected app comes up already locked.
  final pinEnabled =
      await DatabaseHelper.getSettingStr('security_pin_enabled') == '1';
  final pinHash = await DatabaseHelper.getSettingStr('security_pin_hash');
  AppLockService.instance.init(pinEnabled: pinEnabled, pinHash: pinHash);

  runApp(const ProviderScope(child: BusinessProApp()));
}

class BusinessProApp extends ConsumerWidget {
  const BusinessProApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(themeProvider.notifier).loadFromDb();
    });

    return MaterialApp(
      title: AppStrings.appName,
      debugShowCheckedModeBanner: false,
      // Global messenger so a completed sync can confirm itself with a bottom
      // snackbar on any screen (see sync_feedback.dart).
      scaffoldMessengerKey: rootMessengerKey,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      initialRoute: '/',
      routes: {
        '/': (_) => const AppLockWrapper(child: MainShell()),
        '/company-setup': (_) => const CompanySetupScreen(),
        '/items': (_) => const ItemsListScreen(),
        '/inventory': (_) => const InventoryListScreen(),
        '/expense': (_) => const ExpenseListScreen(),
        '/income': (_) => const IncomeListScreen(),
        '/cash-bank': (_) => const AccountsListScreen(),
        '/employees': (_) => const EmployeesListScreen(),
        '/reports': (_) => const ReportsHomeScreen(),
        '/backup': (_) => const BackupScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/sync': (_) => const SyncSettingsScreen(),
      },
    );
  }
}
