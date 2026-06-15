import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';

/// Invoice & purchase numbering prefixes. Each document type can use a Custom
/// prefix (free text) or Monthly mode (auto current-month name, e.g. JUNE),
/// with a live preview of the next number and a per-prefix counter reset.
///
/// Numbering itself flows through `DatabaseHelper.peek/consumeDocNumber`, which
/// key counters as `counter_<type>_<PREFIX>` — so switching a prefix starts a
/// fresh sequence with no collision against the old prefix's numbers.
class PrefixSettingsScreen extends StatefulWidget {
  const PrefixSettingsScreen({super.key});

  @override
  State<PrefixSettingsScreen> createState() => _PrefixSettingsScreenState();
}

class _PrefixSettingsScreenState extends State<PrefixSettingsScreen> {
  bool _loading = true;
  bool _dirty = false; // unsaved changes — enables the Save Changes button
  bool _saving = false;

  // Per type: mode ('custom'|'monthly') + custom prefix text + live preview.
  final _mode = <String, String>{'sale': 'custom', 'purchase': 'custom'};
  final _ctrl = <String, TextEditingController>{
    'sale': TextEditingController(),
    'purchase': TextEditingController(),
  };
  final _preview = <String, String>{'sale': '', 'purchase': ''};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final biz = await DatabaseHelper.getBusiness();
    _ctrl['sale']!.text = (biz?['invoice_prefix'] as String?) ?? 'INV';
    _ctrl['purchase']!.text = (biz?['purchase_prefix'] as String?) ?? 'PUR';
    for (final type in ['sale', 'purchase']) {
      _mode[type] =
          await DatabaseHelper.getSettingStr('prefix_mode_$type', defaultVal: 'custom');
    }
    if (!mounted) return;
    setState(() => _loading = false);
    await _refreshPreviews();
  }

  /// The prefix that would be used for [type] given the current (unsaved) form
  /// state — month name in Monthly mode, else the typed custom text.
  String _effectivePrefix(String type) {
    if (_mode[type] == 'monthly') return DatabaseHelper.monthlyPrefix();
    final t = _ctrl[type]!.text.trim().toUpperCase();
    return t.isEmpty ? (type == 'purchase' ? 'PUR' : 'INV') : t;
  }

  Future<void> _refreshPreviews() async {
    for (final type in ['sale', 'purchase']) {
      _preview[type] =
          await DatabaseHelper.previewDocNumber(type, _effectivePrefix(type));
    }
    if (mounted) setState(() {});
  }

  /// Called whenever the user edits a prefix or toggles mode — marks the form
  /// dirty (enabling Save Changes) and refreshes the live preview.
  void _onChanged() {
    _dirty = true;
    _refreshPreviews();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    for (final type in ['sale', 'purchase']) {
      await DatabaseHelper.setSetting('prefix_mode_$type', _mode[type]!);
      // Persist the effective prefix to the business row so display / numbering
      // agree even outside this screen. In Monthly mode prefixFor() recomputes
      // the month live, but storing it keeps the Company Setup view in sync.
      final col = type == 'purchase' ? 'purchase_prefix' : 'invoice_prefix';
      await DatabaseHelper.updateBusiness({col: _effectivePrefix(type)});
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Prefixes saved — new bills will use them')),
    );
  }

  /// Confirms before leaving with unsaved changes.
  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved prefix changes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep Editing')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return leave ?? false;
  }

  Future<void> _resetCounter(String type) async {
    final prefix = _effectivePrefix(type);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset counter?'),
        content: Text(
            'The next ${type == 'purchase' ? 'purchase' : 'invoice'} under '
            'prefix "$prefix" will restart from 0001. Numbers already issued are '
            'unaffected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await DatabaseHelper.resetCounter(type, prefix);
    await _refreshPreviews();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Counter reset to 0001')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmLeave()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Invoice Prefix')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _section('Sale Invoice', 'sale'),
                  const SizedBox(height: 16),
                  _section('Purchase Bill', 'purchase'),
                  const SizedBox(height: 8),
                  if (DatabaseHelper.deviceDocPrefix.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'This device prepends "W-" to every number so two devices '
                        'never generate the same id.',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
        bottomNavigationBar: _loading
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: (_dirty && !_saving) ? _save : null,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_dirty ? 'Save Changes' : 'Saved',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _section(String title, String type) {
    final monthly = _mode[type] == 'monthly';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.dividerOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          // Mode toggle.
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'custom', label: Text('Custom')),
              ButtonSegment(value: 'monthly', label: Text('Monthly')),
            ],
            selected: {_mode[type]!},
            onSelectionChanged: (s) {
              setState(() => _mode[type] = s.first);
              _onChanged();
            },
          ),
          const SizedBox(height: 12),
          if (!monthly)
            TextField(
              controller: _ctrl[type],
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                _UpperCaseFormatter(),
              ],
              decoration: const InputDecoration(
                labelText: 'Prefix',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _onChanged(),
            )
          else
            Row(
              children: [
                const Icon(Icons.calendar_month_outlined,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Auto: ${DatabaseHelper.monthlyPrefix()} — resets each month',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Next: ',
                  style: TextStyle(color: AppColors.textSecondary)),
              Text(_preview[type] ?? '',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _resetCounter(type),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset counter'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Uppercases prefix input as the user types.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
