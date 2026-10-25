import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'esp_ble_bridge.dart';
import 'esp_provisioning_sheet.dart';
import 'esp_debug_console.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EspBridgeDemoApp());
}

class EspBridgeDemoApp extends StatelessWidget {
  const EspBridgeDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Flutter Bridge Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF02569B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF02569B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const EspBridgeHomePage(),
    );
  }
}

class EspBridgeHomePage extends StatefulWidget {
  const EspBridgeHomePage({super.key});

  @override
  State<EspBridgeHomePage> createState() => _EspBridgeHomePageState();
}

class _EspBridgeHomePageState extends State<EspBridgeHomePage> {
  final EspBleBridge _bridge = EspBleBridge();
  final List<ScanResult> _scanResults = [];
  final List<String> _logs = [];

  bool _isBleScanning = false;
  bool _isConnecting = false;
  bool _ledState = false;
  String? _provisionedIp;
  Map<String, dynamic>? _deviceInfo;

  @override
  void initState() {
    super.initState();

    // Listen to live incoming JSON events
    _bridge.onJsonReceived.listen((data) {
      setState(() {
        _logs.insert(0, "[RX] ${jsonEncode(data)}");
        if (data["ev"] == "ack" && data["cmd"] == "led") {
          _ledState = data["state"] == true;
        }
      });
    });

    // Listen to diagnostics info events
    _bridge.onInfoReceived.listen((info) {
      setState(() {
        _deviceInfo = info;
      });
      _showToast("Cihaz bilgileri güncellendi!");
    });
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  Future<void> _startBleScan() async {
    setState(() {
      _scanResults.clear();
      _isBleScanning = true;
    });

    try {
      final results = await EspBleBridge.scanForDevices(timeout: const Duration(seconds: 4));
      if (mounted) {
        setState(() {
          _scanResults.clear();
          _scanResults.addAll(results);
        });
      }
    } catch (e) {
      _showToast("BLE Tarama hatası: $e");
    } finally {
      if (mounted) setState(() => _isBleScanning = false);
    }
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    setState(() => _isConnecting = true);
    try {
      await _bridge.connect(device);
      _showToast("Bağlandı: ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}");
    } catch (e) {
      _showToast("Bağlantı hatası: $e");
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnectDevice() async {
    await _bridge.disconnect();
    setState(() {
      _deviceInfo = null;
    });
    _showToast("Bağlantı kesildi.");
  }

  Future<void> _openProvisioningModal() async {
    // Demonstrating auto-discovery + custom extraConfig payload
    final ip = await showEspProvisioningSheet(
      context,
      _bridge,
      extraConfig: const {
        "mqtt_host": "broker.emqx.io",
        "device_token": "usr_alpha_9981",
      },
    );

    if (ip != null && mounted) {
      setState(() => _provisionedIp = ip);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("ESP32 internete bağlandı! IP: $ip"),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  Future<void> _toggleLed(bool value) async {
    try {
      await _bridge.sendJson({"cmd": "led", "val": value});
      setState(() {
        _logs.insert(0, "[TX] {\"cmd\":\"led\",\"val\":$value}");
      });
    } catch (e) {
      _showToast("Komut gönderilemedi: $e");
    }
  }

  Future<void> _requestDeviceInfo() async {
    try {
      await _bridge.requestInfo();
      setState(() {
        _logs.insert(0, "[TX] {\"cmd\":\"info\"}");
      });
    } catch (e) {
      _showToast("Bilgi talep edilemedi: $e");
    }
  }

  Future<void> _resetDeviceWifi() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Fabrika Sıfırlaması"),
        content: const Text(
          "ESP32'nin kayıtlı Wi-Fi şifresi ve ayarları silinecek. Emin misiniz?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("İptal"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Sıfırla"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _bridge.resetWifi();
        setState(() {
          _provisionedIp = null;
          _deviceInfo = null;
          _logs.insert(0, "[TX] {\"cmd\":\"reset_wifi\"}");
        });
        _showToast("ESP32 Wi-Fi hafızası temizlendi.");
      } catch (e) {
        _showToast("Sıfırlama hatası: $e");
      }
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text("⚡ ESP32 Flutter Bridge"),
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: "Canlı Log Konsolu",
            onPressed: () => showEspDebugModal(context, _bridge),
          ),
          if (_bridge.isConnected)
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: "Bağlantıyı Kes",
              onPressed: _disconnectDevice,
            )
          else
            IconButton(
              icon: _isBleScanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bluetooth_searching),
              tooltip: "Cihaz Tara",
              onPressed: _isBleScanning ? null : _startBleScan,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Connection Card
          _buildConnectionCard(colorScheme),
          const SizedBox(height: 16),

          // Wi-Fi Provisioning Action Card (with Auto-Discovery)
          _buildProvisioningCard(colorScheme),
          const SizedBox(height: 16),

          // Diagnostics & Factory Reset Card
          _buildDiagnosticsCard(colorScheme),
          const SizedBox(height: 16),

          // Custom Commands Card (LED, Terminal)
          _buildCommandsCard(colorScheme),
          const SizedBox(height: 16),

          // Live Event / Message Logs
          _buildLogConsole(colorScheme),
        ],
      ),
    );
  }

  Widget _buildConnectionCard(ColorScheme colorScheme) {
    final isConnected = _bridge.isConnected;
    final device = _bridge.connectedDevice;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isConnected ? colorScheme.primary : colorScheme.outlineVariant,
        ),
      ),
      color: isConnected
          ? colorScheme.primaryContainer.withOpacity(0.3)
          : colorScheme.surfaceVariant.withOpacity(0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? colorScheme.primary : colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isConnected
                        ? "Bağlı: ${device?.platformName.isNotEmpty == true ? device!.platformName : device?.remoteId}"
                        : "BLE Cihazı Bağlı Değil",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isConnecting)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (!isConnected && _scanResults.isNotEmpty) ...[
              const Divider(height: 24),
              const Text(
                "Bulunan Cihazlar:",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              ..._scanResults.map((result) {
                final name = result.device.platformName.isNotEmpty
                    ? result.device.platformName
                    : "Bilinmeyen Cihaz (${result.device.remoteId})";
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(name),
                  subtitle: Text("${result.rssi} dBm"),
                  trailing: FilledButton.tonal(
                    onPressed: _isConnecting ? null : () => _connectDevice(result.device),
                    child: const Text("Bağlan"),
                  ),
                );
              }),
            ] else if (!isConnected) ...[
              const SizedBox(height: 8),
              Text(
                "İpucu: Wi-Fi Kurulum butonuna tıklarsanız cihaz otomatik olarak aranır ve bağlanır!",
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProvisioningCard(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_settings, color: colorScheme.secondary),
                const SizedBox(width: 8),
                const Text(
                  "Wi-Fi Provisioning & Extra Config",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _provisionedIp != null
                  ? "Cihaz ağa bağlı. Son IP: $_provisionedIp"
                  : "Tek tıkla BLE auto-discovery yapar ve Wi-Fi ile birlikte extraConfig (MQTT/Token) gönderir.",
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openProvisioningModal,
              icon: const Icon(Icons.wifi),
              label: const Text("Wi-Fi Kurulumunu Başlat (Sihirli Akış)"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsCard(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.monitor_heart, color: colorScheme.error),
                    const SizedBox(width: 8),
                    const Text(
                      "Cihaz Tanılama & Sıfırlama",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: "Bilgileri Güncelle",
                  onPressed: _bridge.isConnected ? _requestDeviceInfo : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_deviceInfo != null) ...[
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _buildBadge("Wi-Fi", _deviceInfo!["wifi"] == true ? "Bağlı" : "Kopuk", Colors.green),
                  _buildBadge("SSID", "${_deviceInfo!["ssid"] ?? '-'}", Colors.blue),
                  _buildBadge("IP", "${_deviceInfo!["ip"] ?? '-'}", Colors.teal),
                  _buildBadge("RAM", "${((_deviceInfo!["heap"] ?? 0) / 1024).toStringAsFixed(1)} KB", Colors.orange),
                  _buildBadge("Uptime", "${((_deviceInfo!["uptime"] ?? 0) / 1000).toStringAsFixed(0)}s", Colors.purple),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _bridge.isConnected ? _requestDeviceInfo : null,
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text("Durum Sor (info)"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _bridge.isConnected ? _resetDeviceWifi : null,
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text("Fabrika Sıfırla"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        "$label: $value",
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _buildCommandsCard(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cable, color: colorScheme.tertiary),
                const SizedBox(width: 8),
                const Text(
                  "Çift Yönlü Veri & Canlı Konsol",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("ESP32 LED (GPIO 2)"),
              subtitle: Text(_ledState ? "Açık (HIGH)" : "Kapalı (LOW)"),
              value: _ledState,
              onChanged: _bridge.isConnected ? _toggleLed : null,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => showEspDebugModal(context, _bridge),
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text("Canlı Log Konsolu Aç"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogConsole(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceVariant.withOpacity(0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Ham BLE JSON Akışı",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                TextButton(
                  onPressed: () => setState(() => _logs.clear()),
                  child: const Text("Temizle"),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 140,
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        "Henüz veri akışı yok...",
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        final isTx = log.startsWith("[TX]");
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            log,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: isTx
                                  ? Colors.greenAccent
                                  : Colors.lightBlueAccent,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
