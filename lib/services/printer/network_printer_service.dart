import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/constants/app_strings.dart';
import 'print_settings_repository.dart';
import 'printer_service.dart';

/// Network (WiFi/LAN) thermal printer transport over a raw TCP socket to the
/// standard ESC/POS RAW port 9100. Works on Android and Windows. Network
/// printers can't be auto-discovered reliably, so the user adds them by IP and
/// they are persisted as a JSON array in the `saved_network_printers` setting.
class NetworkPrinterService implements PrinterService {
  static const int port9100 = 9100;

  final PrintSettingsRepository _repo;
  Socket? _socket;

  NetworkPrinterService({PrintSettingsRepository? repo})
      : _repo = repo ?? PrintSettingsRepository();

  @override
  String get connectionType => 'network';

  @override
  Future<List<DiscoveredPrinter>> discoverPrinters() => loadSaved();

  /// The user-saved network printers (also used by the settings screen).
  Future<List<DiscoveredPrinter>> loadSaved() async {
    final raw = await _repo.getString(1, AppStrings.kSavedNetworkPrinters);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list
          .map((m) => DiscoveredPrinter(
                id: m['address'] as String,
                name: (m['name'] as String?) ?? m['address'] as String,
                type: 'network',
                address: m['address'] as String,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Persist a new network printer (name + IP). Replaces any entry with the same
  /// address.
  Future<void> addSaved(String name, String address) async {
    final current = await loadSaved();
    final next = [
      ...current.where((p) => p.address != address),
      DiscoveredPrinter(
          id: address, name: name, type: 'network', address: address),
    ];
    final json = jsonEncode(next
        .map((p) => {'name': p.name, 'address': p.address})
        .toList());
    await _repo.save(1, AppStrings.kSavedNetworkPrinters, json);
  }

  @override
  Future<bool> connect(DiscoveredPrinter printer) async {
    final host = printer.address;
    if (host == null || host.isEmpty) return false;
    try {
      _socket = await Socket.connect(host, port9100,
          timeout: const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> printBytes(Uint8List bytes) async {
    final socket = _socket;
    if (socket == null) throw Exception('Not connected');
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
  }

  @override
  Future<bool> isConnected() async => _socket != null;
}
