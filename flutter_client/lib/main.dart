import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'esp_ble_bridge.dart';
import 'esp_provisioning_sheet.dart';

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

  @override
  void initState() {
    super.initState();

    // Listen to live incoming JSON events from ESP32
    _bridge.onJsonReceived.listen((data) {
      setState(() {
        _logs.insert(0, "[RX] ${jsonEncode(data)}");
        if (data["ev"] == "ack" && data["cmd"] == "led") {
          _ledState = data["state"] == true;
        }
      });
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
      await FlutterBluePlus.startScan(
        withServices: [Guid(EspBleBridge.serviceUuid)],
        timeout: const Duration(seconds: 6),
      );

      FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            _scanResults.clear();
            _scanResults.addAll(results);
          });
        }
      });

      await FlutterBluePlus.isScanning.where((val) => !val).first;
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
    setState(() {});
    _showToast("Bağlantı kesildi.");
  }

  Future<void> _openProvisioningModal() async {
    final ip = await showEspProvisioningSheet(context, _bridge);
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

  Future<void> _sendPing() async {
    try {
      await _bridge.ping();
      setState(() {
        _logs.insert(0, "[TX] {\"cmd\":\"ping\"}");
      });
    } catch (e) {
      _showToast("Ping gönderilemedi: $e");
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

          // Wi-Fi Provisioning Action Card
          _buildProvisioningCard(colorScheme),
          const SizedBox(height: 16),

          // Custom Commands Card (LED, Ping, Custom JSON)
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
          color: isConnected
              ? colorScheme.primary
              : colorScheme.outlineVariant,
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
                Text(
                  isConnected
                      ? "Bağlı: ${device?.platformName.isNotEmpty == true ? device!.platformName : device?.remoteId}"
                      : "BLE Cihazı Bağlı Değil",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
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
                "EspFlutterBridge çalıştıran ESP32 cihazınızı bulmak için yukarıdaki tarama butonuna tıklayın.",
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
                  "Wi-Fi Provisioning",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _provisionedIp != null
                  ? "Cihaz bağlı. Son Alınan IP: $_provisionedIp"
                  : "ESP32'yi çevredeki bir Wi-Fi ağına bağlamak için BottomSheet'i açın.",
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _bridge.isConnected ? _openProvisioningModal : null,
              icon: const Icon(Icons.wifi),
              label: const Text("ESP32 Wi-Fi Ayarla"),
            ),
          ],
        ),
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
                Icon(Icons.terminal, color: colorScheme.tertiary),
                const SizedBox(width: 8),
                const Text(
                  "Çift Yönlü Veri Köprüsü",
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
                  child: OutlinedButton.icon(
                    onPressed: _bridge.isConnected ? _sendPing : null,
                    icon: const Icon(Icons.network_ping),
                    label: const Text("Ping Gönder"),
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
                  "Canlı JSON Akışı",
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
              height: 160,
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
