import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';
import '../constants/app_strings.dart';

class AppSettings {
  final String dateFormat;
  final int decimalPlaces;
  final bool taxEnabled;
  final bool stockTracking;
  final bool lowStockAlert;
  final bool showDiscount;
  final String defaultPaymentMode;
  final int backupReminderDays;
  // Notifications
  final bool notifEnabled;
  final bool notifMonthEndExpense;
  final bool notifBackupReminder;
  final bool notifLowStock;

  const AppSettings({
    this.dateFormat = 'dd/MM/yyyy',
    this.decimalPlaces = 2,
    this.taxEnabled = true,
    this.stockTracking = true,
    this.lowStockAlert = true,
    this.showDiscount = true,
    this.defaultPaymentMode = 'cash',
    this.backupReminderDays = 7,
    this.notifEnabled = true,
    this.notifMonthEndExpense = true,
    this.notifBackupReminder = true,
    this.notifLowStock = true,
  });

  AppSettings copyWith({
    String? dateFormat,
    int? decimalPlaces,
    bool? taxEnabled,
    bool? stockTracking,
    bool? lowStockAlert,
    bool? showDiscount,
    String? defaultPaymentMode,
    int? backupReminderDays,
    bool? notifEnabled,
    bool? notifMonthEndExpense,
    bool? notifBackupReminder,
    bool? notifLowStock,
  }) {
    return AppSettings(
      dateFormat: dateFormat ?? this.dateFormat,
      decimalPlaces: decimalPlaces ?? this.decimalPlaces,
      taxEnabled: taxEnabled ?? this.taxEnabled,
      stockTracking: stockTracking ?? this.stockTracking,
      lowStockAlert: lowStockAlert ?? this.lowStockAlert,
      showDiscount: showDiscount ?? this.showDiscount,
      defaultPaymentMode: defaultPaymentMode ?? this.defaultPaymentMode,
      backupReminderDays: backupReminderDays ?? this.backupReminderDays,
      notifEnabled: notifEnabled ?? this.notifEnabled,
      notifMonthEndExpense: notifMonthEndExpense ?? this.notifMonthEndExpense,
      notifBackupReminder: notifBackupReminder ?? this.notifBackupReminder,
      notifLowStock: notifLowStock ?? this.notifLowStock,
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async => _load();

  Future<AppSettings> _load() async {
    return AppSettings(
      dateFormat: await DatabaseHelper.getSettingStr(AppStrings.kDateFormat, defaultVal: 'dd/MM/yyyy'),
      decimalPlaces: await DatabaseHelper.getSetting(AppStrings.kDecimalPlaces, defaultVal: 2),
      taxEnabled: (await DatabaseHelper.getSetting(AppStrings.kTaxEnabled, defaultVal: 1)) == 1,
      stockTracking: (await DatabaseHelper.getSetting(AppStrings.kStockTracking, defaultVal: 1)) == 1,
      lowStockAlert: (await DatabaseHelper.getSetting(AppStrings.kLowStockAlert, defaultVal: 1)) == 1,
      showDiscount: (await DatabaseHelper.getSetting(AppStrings.kShowDiscount, defaultVal: 1)) == 1,
      defaultPaymentMode: await DatabaseHelper.getSettingStr(AppStrings.kDefaultPaymentMode, defaultVal: 'cash'),
      backupReminderDays: await DatabaseHelper.getSetting(AppStrings.kBackupReminderDays, defaultVal: 7),
      notifEnabled: (await DatabaseHelper.getSetting(AppStrings.kNotifEnabled, defaultVal: 1)) == 1,
      notifMonthEndExpense: (await DatabaseHelper.getSetting(AppStrings.kNotifMonthEndExpense, defaultVal: 1)) == 1,
      notifBackupReminder: (await DatabaseHelper.getSetting(AppStrings.kNotifBackupReminder, defaultVal: 1)) == 1,
      notifLowStock: (await DatabaseHelper.getSetting(AppStrings.kNotifLowStock, defaultVal: 1)) == 1,
    );
  }

  Future<void> set(String key, String value) async {
    await DatabaseHelper.setSetting(key, value);
    state = AsyncData(await _load());
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
