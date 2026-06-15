import 'dart:io';

import '../../core/constants/app_strings.dart';
import '../../features/parties/models/party.dart';
import '../../features/transactions/models/transaction.dart';
import '../../features/transactions/models/transaction_item.dart';
import 'bluetooth_printer_service.dart';
import 'esc_pos_builder.dart';
import 'network_printer_service.dart';
import 'print_settings.dart';
import 'print_settings_repository.dart';
import 'printer_service.dart';
import 'thermal_invoice_formatter.dart';
import 'usb_printer_service.dart';

/// Thrown by [PrinterManager.printTransaction] on Windows when thermal is not
/// the default printer, signalling the caller to fall back to the existing A4
/// PDF print path. Caught by name in the transaction detail screen.
class UsePdfFallback implements Exception {
  const UsePdfFallback();
}

/// Thrown when no default printer has been configured yet.
class NoDefaultPrinter implements Exception {
  const NoDefaultPrinter();
}

/// Single entry point for all thermal printing. Selects a transport, formats the
/// document from [PrintSettings], (re)connects to the saved default printer, and
/// sends the bytes.
class PrinterManager {
  static const int _businessId = 1;

  final PrintSettingsRepository _settingsRepo;
  final ThermalInvoiceFormatter _formatter = ThermalInvoiceFormatter();

  PrinterService? _active;

  PrinterManager(this._settingsRepo);

  PrinterService _serviceFor(String type) {
    switch (type) {
      case 'bluetooth':
        if (!Platform.isAndroid) {
          throw Exception('Bluetooth printing is not supported on this platform');
        }
        return BluetoothPrinterService();
      case 'usb':
        return UsbPrinterService();
      case 'network':
        return NetworkPrinterService(repo: _settingsRepo);
      default:
        throw Exception('Unknown printer type: $type');
    }
  }

  /// Discover printers across every transport available on this platform.
  /// Bluetooth is only attempted on Android. Per-transport failures are
  /// swallowed so one flaky transport never hides the others.
  Future<List<DiscoveredPrinter>> discoverAll() async {
    final results = <DiscoveredPrinter>[];
    if (Platform.isAndroid) {
      try {
        results.addAll(await BluetoothPrinterService().discoverPrinters());
      } catch (_) {}
    }
    try {
      results.addAll(await UsbPrinterService().discoverPrinters());
    } catch (_) {}
    try {
      results.addAll(
          await NetworkPrinterService(repo: _settingsRepo).discoverPrinters());
    } catch (_) {}
    return results;
  }

  /// Connect to [printer] and, on success, persist it as the default.
  Future<bool> connectAndSave(DiscoveredPrinter printer) async {
    await _active?.disconnect();
    _active = _serviceFor(printer.type);
    final connected = await _active!.connect(printer);
    if (connected) {
      await _settingsRepo.save(_businessId, AppStrings.kDefaultPrinterId, printer.id);
      await _settingsRepo.save(
          _businessId, AppStrings.kDefaultPrinterName, printer.name);
      await _settingsRepo.save(
          _businessId, AppStrings.kDefaultPrinterType, printer.type);
      await _settingsRepo.save(_businessId, AppStrings.kDefaultPrinterAddress,
          printer.address ?? '');
    }
    return connected;
  }

  /// Print a transaction. On Windows, if thermal is not the default, throws
  /// [UsePdfFallback] so the caller routes to the existing PDF printer.
  Future<void> printTransaction({
    required Transaction transaction,
    required List<TransactionItem> items,
    required Map<String, dynamic> business,
    Party? party,
    String? paymentModeName,
  }) async {
    final settings = await _settingsRepo.load(_businessId);

    if (Platform.isWindows && !settings.thermalIsDefault) {
      throw const UsePdfFallback();
    }

    final bytes = _isExpense(transaction.transactionType)
        ? _formatter.formatExpenseReceipt(
            transaction: transaction, business: business, settings: settings)
        : _formatter.formatSaleInvoice(
            transaction: transaction,
            items: items,
            business: business,
            settings: settings,
            party: party,
            paymentModeName: paymentModeName,
          );

    await _ensureConnected();
    await _active!.printBytes(bytes);
  }

  /// Print a test receipt using the current paper-size setting.
  Future<void> printTest(Map<String, dynamic> business) async {
    final settings = await _settingsRepo.load(_businessId);
    final paper =
        settings.paperSize == 'mm58' ? PaperSize.mm58 : PaperSize.mm80;
    final bytes = _formatter.formatTestPrint(business, paper);
    await _ensureConnected();
    await _active!.printBytes(bytes);
  }

  Future<void> disconnect() async {
    await _active?.disconnect();
    _active = null;
  }

  bool _isExpense(String type) =>
      type == TxnTypes.expense || type == TxnTypes.otherIncome;

  /// Reuse the live connection if any, otherwise reconnect to the saved default
  /// printer. Throws [NoDefaultPrinter] when none has been configured.
  Future<void> _ensureConnected() async {
    if (_active != null && await _active!.isConnected()) return;

    final id = await _settingsRepo.getString(_businessId, AppStrings.kDefaultPrinterId);
    final type =
        await _settingsRepo.getString(_businessId, AppStrings.kDefaultPrinterType);
    if (id == null || id.isEmpty || type == null || type.isEmpty) {
      throw const NoDefaultPrinter();
    }
    final name =
        await _settingsRepo.getString(_businessId, AppStrings.kDefaultPrinterName);
    final address = await _settingsRepo.getString(
        _businessId, AppStrings.kDefaultPrinterAddress);

    final printer = DiscoveredPrinter(
      id: id,
      name: name ?? '',
      type: type,
      address: (address?.isEmpty ?? true) ? null : address,
    );
    if (!await connectAndSave(printer)) {
      throw Exception('Could not connect to the saved printer');
    }
  }
}
