import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Handles BLE communication between ESP32 and Flutter using
/// a newline-delimited JSON stream over Nordic UART style characteristics.
class EspBleBridge {
  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String rxUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String txUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<List<int>>? _txSubscription;

  final _jsonStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _logStreamController = StreamController<String>.broadcast();
  final _infoStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  String _incomingBuffer = "";

  /// Broadcast stream of parsed incoming JSON payloads.
  Stream<Map<String, dynamic>> get onJsonReceived =>
      _jsonStreamController.stream;

  /// Dedicated broadcast stream of real-time ESP32 log messages (`{"ev":"log","msg":"..."}`).
  Stream<String> get onLogReceived => _logStreamController.stream;

  /// Broadcast stream for device diagnostic updates (`{"ev":"info", ...}`).
  Stream<Map<String, dynamic>> get onInfoReceived =>
      _infoStreamController.stream;

  /// Whether a peripheral is currently connected and ready.
  bool get isConnected => _connectedDevice != null && _rxChar != null;

  /// Reference to the currently connected device.
  BluetoothDevice? get connectedDevice => _connectedDevice;

  /// Helper to scan for nearby ESP32 devices advertising the bridge service UUID.
  static Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final List<ScanResult> results = [];
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUuid)],
        timeout: timeout,
      );
      await FlutterBluePlus.isScanning.where((v) => !v).first;
      results.addAll(FlutterBluePlus.lastScanResults);
    } catch (_) {}
    return results;
  }

  /// Connect to an ESP32 BLE device and discover the bridge service & characteristics.
  Future<void> connect(
    BluetoothDevice device, {
    int targetMtu = 256,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _connectedDevice = device;
    await device.connect(autoConnect: false).timeout(timeout);

    // Request higher MTU on Android (iOS negotiates automatically)
    try {
      await device.requestMtu(targetMtu);
    } catch (_) {
      // Ignored if unsupported or already negotiated
    }

    final services = await device.discoverServices();
    for (final s in services) {
      if (s.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
        for (final c in s.characteristics) {
          if (c.uuid.toString().toLowerCase() == rxUuid.toLowerCase()) {
            _rxChar = c;
          }
          if (c.uuid.toString().toLowerCase() == txUuid.toLowerCase()) {
            _txChar = c;
            await c.setNotifyValue(true);
            _txSubscription?.cancel();
            _txSubscription = c.onValueReceived.listen(_onRawBytesReceived);
          }
        }
      }
    }

    if (_rxChar == null || _txChar == null) {
      throw StateError(
        "EspFlutterBridge service or characteristics not found on ${device.remoteId}.",
      );
    }
  }

  /// Disconnects from the current BLE device and resets state.
  Future<void> disconnect() async {
    _txSubscription?.cancel();
    _txSubscription = null;
    _rxChar = null;
    _txChar = null;
    _incomingBuffer = "";

    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
      _connectedDevice = null;
    }
  }

  /// Processes raw incoming bytes, buffering them until '\n' is encountered,
  /// then decoding and emitting JSON objects.
  void _onRawBytesReceived(List<int> bytes) {
    if (bytes.isEmpty) return;
    _incomingBuffer += utf8.decode(bytes, allowMalformed: true);

    while (_incomingBuffer.contains('\n')) {
      final index = _incomingBuffer.indexOf('\n');
      final line = _incomingBuffer.substring(0, index).trim();
      _incomingBuffer = _incomingBuffer.substring(index + 1);

      if (line.isNotEmpty) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            _jsonStreamController.add(decoded);

            // Route special events to dedicated sub-streams
            final event = decoded["ev"];
            if (event == "log" && decoded["msg"] != null) {
              _logStreamController.add(decoded["msg"].toString());
            } else if (event == "info") {
              _infoStreamController.add(decoded);
            }
          }
        } catch (_) {
          // Discard malformed packets
        }
      }
    }
  }

  /// Sends a JSON object to ESP32 by splitting into MTU-safe chunks.
  Future<void> sendJson(
    Map<String, dynamic> data, {
    int chunkSize = 180,
  }) async {
    final payload = "${jsonEncode(data)}\n";
    await sendRawString(payload, chunkSize: chunkSize);
  }

  /// Sends a raw string split into safe chunks with a trailing newline.
  Future<void> sendRawString(
    String str, {
    int chunkSize = 180,
  }) async {
    if (_rxChar == null) {
      throw StateError("Cannot send: ESP32 RX characteristic is not connected.");
    }

    final payload = str.endsWith("\n") ? str : "$str\n";
    final bytes = utf8.encode(payload);

    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      final chunk = bytes.sublist(i, end);
      await _rxChar!.write(chunk, withoutResponse: false);
    }
  }

  // --- Convenience Command Helpers ---

  /// Triggers a Wi-Fi scan on the ESP32.
  Future<void> scanWifi() => sendJson(const {"cmd": "scan"});

  /// Tells the ESP32 to connect to a Wi-Fi network and save credentials to NVS.
  /// Optionally sends custom provisioning parameters (e.g., MQTT broker, API token)
  /// stored in [extraConfig].
  Future<void> connectWifi(
    String ssid,
    String pass, {
    Map<String, dynamic>? extraConfig,
  }) {
    final Map<String, dynamic> payload = {
      "cmd": "wifi",
      "s": ssid,
      "p": pass,
    };
    if (extraConfig != null && extraConfig.isNotEmpty) {
      payload["extra"] = extraConfig;
    }
    return sendJson(payload);
  }

  /// Requests device diagnostics (Wi-Fi status, IP, RSSI, Free Heap, Uptime).
  Future<void> requestInfo() => sendJson(const {"cmd": "info"});

  /// Erases saved Wi-Fi credentials and extra config from NVS, and disconnects Wi-Fi.
  Future<void> resetWifi() => sendJson(const {"cmd": "reset_wifi"});

  /// Pings the ESP32.
  Future<void> ping() => sendJson(const {"cmd": "ping"});

  /// Disposes active subscriptions and controllers.
  void dispose() {
    _txSubscription?.cancel();
    _jsonStreamController.close();
    _logStreamController.close();
    _infoStreamController.close();
  }
}
