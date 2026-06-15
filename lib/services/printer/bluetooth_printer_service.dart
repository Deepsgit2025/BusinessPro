import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'printer_service.dart';

/// Bluetooth thermal printer transport. **Android only** — flutter_blue_plus has
/// no Windows support, so [PrinterManager] guards every use with
/// `Platform.isAndroid` and never instantiates this on Windows.
///
/// Uses bonded (paired) devices rather than active scanning: thermal printers
/// are paired once in the OS settings, and bonded-list connect is far more
/// reliable on cheap printers than rediscovering them each time.
class BluetoothPrinterService implements PrinterService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;

  @override
  String get connectionType => 'bluetooth';

  @override
  Future<List<DiscoveredPrinter>> discoverPrinters() async {
    final devices = await FlutterBluePlus.bondedDevices;
    return devices
        .map((d) => DiscoveredPrinter(
              id: d.remoteId.str,
              name: d.platformName.isEmpty
                  ? 'Bluetooth Printer'
                  : d.platformName,
              type: 'bluetooth',
            ))
        .toList();
  }

  @override
  Future<bool> connect(DiscoveredPrinter printer) async {
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      final device = bonded.firstWhere((d) => d.remoteId.str == printer.id);
      await device.connect(timeout: const Duration(seconds: 10));
      _device = device;
      _writeChar = await _findWritableCharacteristic(device);
      return _writeChar != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> printBytes(Uint8List bytes) async {
    final char = _writeChar;
    if (_device == null || char == null) throw Exception('Not connected');

    // 512-byte chunks with a 20ms gap. Larger chunks overflow the receive
    // buffer on cheap printers and silently drop data — non-negotiable.
    const chunkSize = 512;
    final withoutResponse = char.properties.writeWithoutResponse;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      await char.write(bytes.sublist(i, end),
          withoutResponse: withoutResponse);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _writeChar = null;
  }

  @override
  Future<bool> isConnected() async => _device?.isConnected ?? false;

  Future<BluetoothCharacteristic?> _findWritableCharacteristic(
      BluetoothDevice device) async {
    final services = await device.discoverServices();
    for (final service in services) {
      for (final char in service.characteristics) {
        if (char.properties.write || char.properties.writeWithoutResponse) {
          return char;
        }
      }
    }
    return null;
  }
}
