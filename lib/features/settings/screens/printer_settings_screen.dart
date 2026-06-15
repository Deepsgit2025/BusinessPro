import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../services/printer/network_printer_service.dart';
import '../../../services/printer/printer_manager.dart';
import '../../../services/printer/printer_providers.dart';
import '../../../services/printer/printer_service.dart';

/// Printer settings: choose Regular vs Thermal as default, pick paper size,
/// scan / connect printers, set a default, add a network printer, and run a
/// test print. Every toggle writes a `print_*` key through
/// [PrintSettingsRepository], which is the single source of truth for printing.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() =>
      _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  static const _businessId = 1;

  List<DiscoveredPrinter> _found = [];
  bool _scanning = false;
  bool _busy = false;

  Future<void> _save(String key, String value) async {
    await ref.read(printSettingsRepoProvider).save(_businessId, key, value);
    ref.invalidate(printSettingsProvider(_businessId));
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final found = await ref.read(printerManagerProvider).discoverAll();
      if (mounted) setState(() => _found = found);
    } catch (e) {
      _snack('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _setDefault(DiscoveredPrinter p) async {
    setState(() => _busy = true);
    try {
      final ok = await ref.read(printerManagerProvider).connectAndSave(p);
      if (!ok) {
        _snack('Could not connect to ${p.name}');
      } else {
        ref.invalidate(printSettingsProvider(_businessId));
        _snack('${p.name} set as default ✓');
      }
    } catch (e) {
      _snack('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testPrint() async {
    setState(() => _busy = true);
    try {
      final biz = await DatabaseHelper.getBusiness() ?? const {};
      await ref.read(printerManagerProvider).printTest(biz);
      _snack('Test sent to printer ✓');
    } on NoDefaultPrinter {
      _snack('No default printer set. Scan and set one first.');
    } on UsePdfFallback {
      _snack('Thermal is off on Windows — enable it or use Print PDF.');
    } catch (e) {
      _snack('Test print failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(printSettingsProvider(_businessId));

    return Scaffold(
      appBar: AppBar(title: const Text('Printer Settings')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (s) {
          final defaultName = ref
              .read(printSettingsRepoProvider)
              .getString(_businessId, AppStrings.kDefaultPrinterName);

          return ListView(
            children: [
              _section('Print Type'),
              SwitchListTile(
                value: s.thermalIsDefault,
                onChanged: _busy
                    ? null
                    : (v) => _save(AppStrings.kPrintThermalDefault, v ? '1' : '0'),
                title: const Text('Use Thermal Printer by Default'),
                subtitle: Text(s.thermalIsDefault
                    ? 'Thermal (ESC/POS)'
                    : 'Regular (PDF / A4–A5)'),
                secondary:
                    const Icon(Icons.receipt_long_outlined, color: AppColors.primary),
                activeThumbColor: AppColors.primary,
              ),
              const Divider(height: 0),

              _section('Default Printer'),
              FutureBuilder<String?>(
                future: defaultName,
                builder: (_, snap) {
                  final name = (snap.data?.isNotEmpty ?? false)
                      ? snap.data!
                      : 'None set';
                  return ListTile(
                    leading: const Icon(Icons.print, color: AppColors.primary),
                    title: Text(name),
                    subtitle: const Text('Tap Test Print to verify'),
                    trailing: TextButton(
                      onPressed: _busy ? null : _testPrint,
                      child: const Text('Test Print'),
                    ),
                  );
                },
              ),
              const Divider(height: 0),

              _section('Paper Size'),
              ListTile(
                leading: const Icon(Icons.straighten, color: AppColors.primary),
                title: const Text('Paper Width'),
                trailing: DropdownButton<String>(
                  value: s.paperSize == 'mm58' ? 'mm58' : 'mm80',
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'mm80', child: Text('80 mm (3 inch)')),
                    DropdownMenuItem(value: 'mm58', child: Text('58 mm (2 inch)')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) _save(AppStrings.kPrintPaperSize, v);
                        },
                ),
              ),
              const Divider(height: 0),

              _section('Thermal Options'),
              SwitchListTile(
                value: s.autoCutPaper,
                onChanged: _busy
                    ? null
                    : (v) => _save(AppStrings.kPrintAutoCut, v ? '1' : '0'),
                title: const Text('Auto-cut Paper'),
                activeThumbColor: AppColors.primary,
              ),
              ListTile(
                title: const Text('Copies'),
                trailing: DropdownButton<int>(
                  value: s.numberOfCopies.clamp(1, 5),
                  underline: const SizedBox.shrink(),
                  items: [for (var i = 1; i <= 5; i++) i]
                      .map((n) =>
                          DropdownMenuItem(value: n, child: Text('$n')))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) =>
                          _save(AppStrings.kPrintCopies, (v ?? 1).toString()),
                ),
              ),
              const Divider(height: 0),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('AVAILABLE PRINTERS',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                          letterSpacing: 0.8,
                        )),
                    TextButton.icon(
                      onPressed: _scanning ? null : _scan,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search, size: 18),
                      label: Text(_scanning ? 'Scanning…' : 'Scan'),
                    ),
                  ],
                ),
              ),
              if (_found.isEmpty && !_scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No printers found yet. Tap Scan.',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
              ..._found.map(_printerTile),

              ListTile(
                leading:
                    const Icon(Icons.add_link, color: AppColors.primary),
                title: const Text('Add Network Printer'),
                subtitle: const Text('Connect by IP address (port 9100)'),
                onTap: _busy ? null : _addNetworkDialog,
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _printerTile(DiscoveredPrinter p) {
    IconData icon;
    switch (p.type) {
      case 'bluetooth':
        icon = Icons.bluetooth;
      case 'usb':
        icon = Icons.usb;
      default:
        icon = Icons.wifi;
    }
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(p.name),
      subtitle: Text(p.address ?? p.type),
      trailing: TextButton(
        onPressed: _busy ? null : () => _setDefault(p),
        child: const Text('Set Default'),
      ),
    );
  }

  Future<void> _addNetworkDialog() async {
    final nameCtrl = TextEditingController();
    final ipCtrl = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Network Printer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Printer Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ipCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                hintText: '192.168.1.100',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (added == true) {
      final ip = ipCtrl.text.trim();
      if (ip.isEmpty) {
        _snack('Enter an IP address');
        return;
      }
      final name = nameCtrl.text.trim().isEmpty ? ip : nameCtrl.text.trim();
      // Persist via the same repository the manager uses, so the printer shows
      // up on the next scan and can be reconnected from saved settings.
      final net = NetworkPrinterService(
          repo: ref.read(printSettingsRepoProvider));
      await net.addSaved(name, ip);
      await _scan();
      _snack('Added $name');
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
              letterSpacing: 0.8,
            )),
      );

}
