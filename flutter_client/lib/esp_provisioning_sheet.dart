import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'esp_ble_bridge.dart';

/// Opens the ready-to-use ESP32 Wi-Fi Provisioning modal bottom sheet.
///
/// If [device] is passed and [bridge] is not yet connected, it connects automatically.
/// Returns the ESP32 IP address (String?) upon successful connection, or null if dismissed.
Future<String?> showEspProvisioningSheet(
  BuildContext context,
  EspBleBridge bridge, {
  BluetoothDevice? device,
  String title = "ESP32 Wi-Fi Kurulumu",
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _EspProvisioningSheetContent(
      bridge: bridge,
      device: device,
      title: title,
    ),
  );
}

class _EspProvisioningSheetContent extends StatefulWidget {
  final EspBleBridge bridge;
  final BluetoothDevice? device;
  final String title;

  const _EspProvisioningSheetContent({
    required this.bridge,
    this.device,
    required this.title,
  });

  @override
  State<_EspProvisioningSheetContent> createState() =>
      _EspProvisioningSheetContentState();
}

class _EspProvisioningSheetContentState
    extends State<_EspProvisioningSheetContent> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  final TextEditingController _passController = TextEditingController();

  List<Map<String, dynamic>> _networks = [];
  String? _selectedSsid;
  bool _isConnectingDevice = false;
  bool _isScanning = true;
  bool _isConnectingWifi = false;
  bool _obscurePass = true;
  String? _statusMessage;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.bridge.onJsonReceived.listen(_handleIncomingJson);
    _initFlow();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _initFlow() async {
    // Connect to device if specified and not yet connected
    if (widget.device != null && !widget.bridge.isConnected) {
      setState(() {
        _isConnectingDevice = true;
        _statusMessage = "ESP32 cihazına bağlanılıyor...";
      });

      try {
        await widget.bridge.connect(widget.device!);
        if (!mounted) return;
        setState(() {
          _isConnectingDevice = false;
          _statusMessage = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isConnectingDevice = false;
          _isScanning = false;
          _hasError = true;
          _statusMessage = "Cihaza bağlanılamadı: ${e.toString()}";
        });
        return;
      }
    }

    _startScan();
  }

  void _startScan() {
    if (!widget.bridge.isConnected) {
      setState(() {
        _isScanning = false;
        _hasError = true;
        _statusMessage = "ESP32 BLE bağlı değil.";
      });
      return;
    }

    setState(() {
      _isScanning = true;
      _statusMessage = null;
      _hasError = false;
    });

    widget.bridge.scanWifi().catchError((err) {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _hasError = true;
          _statusMessage = "Tarama başlatılamadı: $err";
        });
      }
    });
  }

  void _handleIncomingJson(Map<String, dynamic> json) {
    final event = json["ev"];

    // 1. Wi-Fi Scan Results
    if (event == "nets") {
      final List rawList = json["list"] ?? [];
      final Map<String, Map<String, dynamic>> uniqueNets = {};

      // Filter Mesh/Repeater duplicates and keep strongest RSSI
      for (var item in rawList) {
        final ssid = (item["s"] ?? "").toString();
        final rssi = (item["r"] ?? -100) as int;
        if (ssid.isNotEmpty) {
          if (!uniqueNets.containsKey(ssid) ||
              rssi > (uniqueNets[ssid]!["r"] as int)) {
            uniqueNets[ssid] = {"s": ssid, "r": rssi};
          }
        }
      }

      final sorted = uniqueNets.values.toList()
        ..sort((a, b) => (b["r"] as int).compareTo(a["r"] as int));

      if (mounted) {
        setState(() {
          _networks = sorted;
          _isScanning = false;
        });
      }
    }
    // 2. Wi-Fi Provisioning Status
    else if (event == "status") {
      final status = json["s"];
      if (status == "connecting") {
        if (mounted) {
          setState(() {
            _isConnectingWifi = true;
            _hasError = false;
            _statusMessage = "'$_selectedSsid' ağına bağlanılıyor...";
          });
        }
      } else if (status == "connected") {
        final ip = json["ip"]?.toString() ?? "Bağlandı";
        if (mounted) {
          setState(() {
            _isConnectingWifi = false;
            _hasError = false;
            _statusMessage = "Başarılı! IP: $ip";
          });
        }
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) Navigator.of(context).pop(ip);
        });
      } else if (status == "failed") {
        if (mounted) {
          setState(() {
            _isConnectingWifi = false;
            _hasError = true;
            _statusMessage = "Bağlantı başarısız. Şifreyi kontrol edip tekrar deneyin.";
          });
        }
      }
    }
  }

  void _connectToWifi() {
    if (_selectedSsid == null) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _isConnectingWifi = true;
      _hasError = false;
      _statusMessage = "Kimlik bilgileri ESP32'ye aktarılıyor...";
    });

    widget.bridge.connectWifi(_selectedSsid!, _passController.text.trim());
  }

  IconData _getRssiIcon(int rssi) {
    if (rssi >= -60) return Icons.wifi;
    if (rssi >= -75) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: bottomInset,
        left: 20,
        right: 20,
        top: 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (_selectedSsid != null && !_isConnectingWifi)
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                        onPressed: () => setState(() {
                          _selectedSsid = null;
                          _statusMessage = null;
                          _passController.clear();
                        }),
                      ),
                    Flexible(
                      child: Text(
                        _selectedSsid ?? widget.title,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_selectedSsid == null && !_isConnectingDevice)
                IconButton(
                  onPressed: _isScanning ? null : _startScan,
                  icon: _isScanning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: "Yeniden Tara",
                ),
            ],
          ),
          const Divider(height: 24),

          // Status message box
          if (_statusMessage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _hasError
                    ? colorScheme.errorContainer
                    : colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _hasError ? Icons.error_outline : Icons.info_outline,
                    color: _hasError
                        ? colorScheme.onErrorContainer
                        : colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        color: _hasError
                            ? colorScheme.onErrorContainer
                            : colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Main View: Network List or Password Form
          if (_isConnectingDevice)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text("ESP32 cihazına bağlanılıyor..."),
                ],
              ),
            )
          else if (_selectedSsid == null)
            _buildNetworkList(colorScheme)
          else
            _buildPasswordForm(colorScheme),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildNetworkList(ColorScheme colorScheme) {
    if (_isScanning) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("ESP32 çevredeki Wi-Fi ağlarını tarıyor..."),
          ],
        ),
      );
    }

    if (_networks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            Icon(Icons.wifi_off, size: 48, color: colorScheme.outline),
            const SizedBox(height: 12),
            const Text("Hiçbir Wi-Fi ağı bulunamadı."),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text("Tekrar Dene"),
            ),
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _networks.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final net = _networks[index];
          final String ssid = net["s"];
          final int rssi = net["r"];

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Icon(_getRssiIcon(rssi), color: colorScheme.primary),
            title: Text(
              ssid,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text("$rssi dBm"),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => setState(() {
              _selectedSsid = ssid;
              _statusMessage = null;
            }),
          );
        },
      ),
    );
  }

  Widget _buildPasswordForm(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _passController,
          obscureText: _obscurePass,
          enabled: !_isConnectingWifi,
          autofocus: true,
          onSubmitted: (_) => _connectToWifi(),
          decoration: InputDecoration(
            labelText: "Wi-Fi Şifresi",
            prefixIcon: const Icon(Icons.lock_outline),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePass ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _isConnectingWifi ? null : _connectToWifi,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: _isConnectingWifi
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.wifi_find),
          label: Text(
            _isConnectingWifi ? "Bağlanıyor..." : "Cihazı Ağa Bağla",
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
