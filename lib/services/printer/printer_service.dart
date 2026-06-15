import 'dart:typed_data';

/// A printer the user can connect to, surfaced by discovery. [address] holds the
/// IP for network printers (null otherwise).
class DiscoveredPrinter {
  final String id;
  final String name;
  final String type; // 'bluetooth' | 'usb' | 'network'
  final String? address;

  const DiscoveredPrinter({
    required this.id,
    required this.name,
    required this.type,
    this.address,
  });
}

/// One transport for sending raw ESC/POS bytes to a thermal printer. Concrete
/// implementations: Bluetooth (Android), USB (Android + Windows), Network (both).
abstract class PrinterService {
  Future<List<DiscoveredPrinter>> discoverPrinters();
  Future<bool> connect(DiscoveredPrinter printer);
  Future<void> disconnect();
  Future<void> printBytes(Uint8List bytes);
  Future<bool> isConnected();
  String get connectionType;
}
