import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_colors.dart';
import '../constants/app_strings.dart';
import '../database/database_helper.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import 'settings_provider.dart';

/// Severity drives the leading-icon colour / accent of a notification.
enum NotifSeverity { info, warning, action }

/// One in-app notification surfaced through the dashboard bell.
class AppNotification {
  /// Stable identifier for the *kind* of notification (used for dismissal).
  final String id;
  final String title;
  final String body;
  final IconData icon;
  final NotifSeverity severity;

  /// Route to push when the notification's primary action is tapped.
  final String? actionRoute;

  /// Label for the primary action button (e.g. "Log Expense"). Null ⇒ no button.
  final String? actionLabel;

  /// Optional setting key written ('yyyy-MM' or '1') when the user dismisses
  /// this notification, so it doesn't immediately reappear.
  final String? dismissKey;
  final String? dismissValue;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.icon,
    this.severity = NotifSeverity.info,
    this.actionRoute,
    this.actionLabel,
    this.dismissKey,
    this.dismissValue,
  });

  Color get color => switch (severity) {
        NotifSeverity.info => AppColors.partial,
        NotifSeverity.warning => AppColors.pending,
        NotifSeverity.action => AppColors.primary,
      };
}

/// Builds the live list of in-app notifications from current app state and the
/// user's per-type notification preferences. Re-evaluates whenever settings or
/// the underlying transaction lists change.
final notificationsProvider =
    FutureProvider<List<AppNotification>>((ref) async {
  final settings = await ref.watch(settingsProvider.future);
  if (!settings.notifEnabled) return const [];

  final out = <AppNotification>[];

  // ── 1. Month-end expense reminder ──────────────────────────────────────────
  // Fires in the "month is wrapping up" window (28th → 5th of next month) when
  // the month being reminded about has no expenses logged yet.
  if (settings.notifMonthEndExpense) {
    final n = await _monthEndExpenseNotification(ref);
    if (n != null) out.add(n);
  }

  // ── 2. Backup reminder ─────────────────────────────────────────────────────
  if (settings.notifBackupReminder && settings.backupReminderDays > 0) {
    final n = await _backupReminderNotification(settings.backupReminderDays);
    if (n != null) out.add(n);
  }

  // ── 3. Low stock ───────────────────────────────────────────────────────────
  if (settings.notifLowStock && settings.lowStockAlert) {
    final n = await _lowStockNotification();
    if (n != null) out.add(n);
  }

  return out;
});

/// Convenience: how many active notifications (drives the bell badge).
final notificationCountProvider = Provider<int>((ref) {
  return ref.watch(notificationsProvider).valueOrNull?.length ?? 0;
});

// ── Builders ──────────────────────────────────────────────────────────────────

/// Returns the (year, month) the reminder should target given today's date, or
/// null if we're outside the reminder window. Window: from the 28th of a month
/// through the 5th of the next month. Before the month flips we remind about the
/// *current* month; after it flips we remind about the month just ended.
({int year, int month})? _reminderTargetMonth(DateTime now) {
  if (now.day >= 28) {
    return (year: now.year, month: now.month); // wrapping up the current month
  }
  if (now.day <= 5) {
    final prev = DateTime(now.year, now.month - 1, 1); // month just ended
    return (year: prev.year, month: prev.month);
  }
  return null;
}

String _monthKey(int year, int month) =>
    '$year-${month.toString().padLeft(2, '0')}';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

Future<AppNotification?> _monthEndExpenseNotification(Ref ref) async {
  final now = DateTime.now();
  final target = _reminderTargetMonth(now);
  if (target == null) return null;

  final key = _monthKey(target.year, target.month);

  // Already dismissed for this exact month? Stay quiet.
  final dismissed = await DatabaseHelper.getSettingStr(
    AppStrings.kMonthEndExpenseDismissed,
  );
  if (dismissed == key) return null;

  // Any expense logged in the target month suppresses the reminder.
  final expenses = await ref.watch(expenseListProvider.future);
  final hasExpense = expenses.any((t) {
    final d = DateTime.tryParse(t.transactionDate);
    return d != null && d.year == target.year && d.month == target.month;
  });
  if (hasExpense) return null;

  final monthName = _monthNames[target.month - 1];
  final isOver = !(now.day >= 28 &&
      target.year == now.year &&
      target.month == now.month);

  return AppNotification(
    id: 'month_end_expense_$key',
    title: isOver ? '$monthName has ended' : '$monthName is almost over',
    body: isOver
        ? "You haven't logged any expenses for $monthName. Add them so your books stay accurate."
        : "No expenses logged for $monthName yet. Log them before the month closes.",
    icon: Icons.event_note_outlined,
    severity: NotifSeverity.action,
    actionRoute: '/expense',
    actionLabel: 'Log Expense',
    dismissKey: AppStrings.kMonthEndExpenseDismissed,
    dismissValue: key,
  );
}

Future<AppNotification?> _backupReminderNotification(int reminderDays) async {
  final lastStr = await DatabaseHelper.getSettingStr(AppStrings.kLastBackupAt);
  final last = DateTime.tryParse(lastStr);
  final now = DateTime.now();

  final daysSince = last == null ? null : now.difference(last).inDays;
  if (daysSince != null && daysSince < reminderDays) return null;

  return AppNotification(
    id: 'backup_reminder',
    title: 'Time to back up',
    body: last == null
        ? "You haven't backed up your data yet. Keep it safe with a backup."
        : "Your last backup was $daysSince day${daysSince == 1 ? '' : 's'} ago.",
    icon: Icons.backup_outlined,
    severity: NotifSeverity.warning,
    actionRoute: '/backup',
    actionLabel: 'Back up',
  );
}

Future<AppNotification?> _lowStockNotification() async {
  final db = await DatabaseHelper.database;
  final rows = await db.rawQuery(
    "SELECT COUNT(*) AS c FROM items "
    "WHERE is_active = 1 AND item_type = 'product' "
    "AND min_stock_level > 0 AND current_stock <= min_stock_level",
  );
  final count = (rows.first['c'] as int?) ?? 0;
  if (count == 0) return null;

  return AppNotification(
    id: 'low_stock',
    title: 'Low stock alert',
    body: '$count item${count == 1 ? '' : 's'} '
        '${count == 1 ? 'has' : 'have'} reached the reorder level.',
    icon: Icons.warning_amber_outlined,
    severity: NotifSeverity.warning,
    actionRoute: '/items',
    actionLabel: 'View Items',
  );
}

/// Marks a notification as dismissed (writes its dismiss key) and refreshes.
Future<void> dismissNotification(WidgetRef ref, AppNotification n) async {
  if (n.dismissKey != null) {
    await DatabaseHelper.setSetting(n.dismissKey!, n.dismissValue ?? '1');
  }
  ref.invalidate(notificationsProvider);
}
