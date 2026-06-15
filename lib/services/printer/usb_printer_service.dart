import 'dart:typed_data';

import 'printer_service.dart';

/// USB thermal printer transport — **temporarily disabled**.
///
/// The only published `usb_serial` package (0.5.2) ships an outdated Android
/// Gradle config that fails to configure under this project's modern AGP and
/// breaks the release build, and there is no newer release. Until a maintained
/// USB-serial plugin is wired in, this transport reports no devices and refuses
/// to connect, so discovery and the printer manager keep working without it
/// (Bluetooth and Network thermal printing are unaffected).
///
/// To re-enable: add a working USB-serial dependency, then restore the
/// list/connect/write implementation against its API.
class UsbPrinterService implements PrinterService {
  @override
  String get connectionType => 'usb';

  @override
  Future<List<DiscoveredPrinter>> discoverPrinters() async => const [];

  @override
  Future<bool> connect(DiscoveredPrinter printer) async => false;

  @override
  Future<void> printBytes(Uint8List bytes) async =>
      throw Exception('USB printing is not available in this build');

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> isConnected() async => false;
}
