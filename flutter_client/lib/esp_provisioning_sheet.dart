import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'esp_ble_bridge.dart';

/// Opens the ready-to-use ESP32 Wi-Fi Provisioning modal bottom sheet.
///
/// Features:
/// - **Auto-Discovery:** If [bridge] is not yet connected, automatically scans for
///   nearby ESP32 devices advertising the bridge service.
/// - **Zero-Touch Connect:** If exactly one ESP32 is found, automatically connects
///   and transitions directly into Wi-Fi network scanning!
/// - **Extra Config (Custom Payload):** Passes optional [extraConfig] (e.g. MQTT broker,
///   auth tokens, device IDs) to the ESP32 to be stored in NVS.
///
/// Returns the ESP32 IP address (String?) upon successful connection, or null if dismissed.
Future<String?> showEspProvisioningSheet(
  BuildContext context,
  EspBleBridge bridge, {
  BluetoothDevice? device,
  Map<String, dynamic>? extraConfig,
  String title = "ESP32 Wi-Fi Kurulumu",
  bool autoConnectSingleDevice = true,
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
      extraConfig: extraConfig,
      title: title,
      autoConnectSingleDevice: autoConnectSingleDevice,
    ),
  );
}

class _EspProvisioningSheetContent extends StatefulWidget {
  final EspBleBridge bridge;
  final BluetoothDevice? device;
  final Map<String, dynamic>? extraConfig;
  final String title;
  final bool autoConnectSingleDevice;

  const _EspProvisioningSheetContent({
    required this.bridge,
    this.device,
    this.extraConfig,
    required this.title,
    required this.autoConnectSingleDevice,
  });

  @override
  State<_EspProvisioningSheetContent> createState() =>
      _EspProvisioningSheetContentState();
}

enum _ProvisioningStep {
  discoveringBle,
  selectingBleDevice,
  scanningWifi,
  enteringPassword,
}

class _EspProvisioningSheetContentState
    extends State<_EspProvisioningSheetContent> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  final TextEditingController _passController = TextEditingController();

  _ProvisioningStep _step = _ProvisioningStep.scanningWifi;
  final List<ScanResult> _discoveredBleDevices = [];
  List<Map<String, dynamic>> _networks = [];
  String? _selectedSsid;
  bool _isConnectingDevice = false;
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
    // If specific device was provided, connect directly
    if (widget.device != null && !widget.bridge.isConnected) {
      await _connectToBleDevice(widget.device!);
      return;
    }

    // If already connected, jump straight to Wi-Fi scan
    if (widget.bridge.isConnected) {
      _startWifiScan();
      return;
    }

    // Otherwise, start BLE Auto-Discovery
    _startBleDiscovery();
  }

  // --- Step 1: BLE Auto-Discovery & Zero-Touch Connect ---

  Future<void> _startBleDiscovery() async {
    setState(() {
      _step = _ProvisioningStep.discoveringBle;
      _discoveredBleDevices.clear();
      _statusMessage = "Çevredeki ESP32 cihazları aranıyor...";
      _hasError = false;
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(EspBleBridge.serviceUuid)],
        timeout: const Duration(milliseconds: 2800),
      );

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            _discoveredBleDevices.clear();
            _discoveredBleDevices.addAll(results);
          });
        }
      });

      await FlutterBluePlus.isScanning.where((val) => !val).first;
      await subscription.cancel();

      if (!mounted) return;

      // Magical Zero-Touch Connect: Exactly 1 ESP32 found!
      if (_discoveredBleDevices.length == 1 && widget.autoConnectSingleDevice) {
        final singleDevice = _discoveredBleDevices.first.device;
        final name = singleDevice.platformName.isNotEmpty
            ? singleDevice.platformName
            : "ESP32";
        setState(() {
          _statusMessage = "'$name' bulundu, otomatik bağlanılıyor...";
        });
        await _connectToBleDevice(singleDevice);
      } else if (_discoveredBleDevices.isEmpty) {
        setState(() {
          _hasError = true;
          _statusMessage = "Çevrede EspFlutterBridge çalıştıran cihaz bulunamadı.";
        });
      } else {
        // Multiple devices found, show selection list
        setState(() {
          _step = _ProvisioningStep.selectingBleDevice;
          _statusMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusMessage = "Bluetooth tarama hatası: $e";
        });
      }
    }
  }

  Future<void> _connectToBleDevice(BluetoothDevice device) async {
    setState(() {
      _isConnectingDevice = true;
      _statusMessage = "'${device.platformName.isNotEmpty ? device.platformName : "ESP32"}' cihazına bağlanılıyor...";
      _hasError = false;
    });

    try {
      await widget.bridge.connect(device);
      if (!mounted) return;
      setState(() {
        _isConnectingDevice = false;
        _statusMessage = null;
      });
      _startWifiScan();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnectingDevice = false;
        _hasError = true;
        _statusMessage = "Cihaza bağlanılamadı: $e";
        _step = _discoveredBleDevices.length > 1
            ? _ProvisioningStep.selectingBleDevice
            : _ProvisioningStep.discoveringBle;
      });
    }
  }

  // --- Step 2: Wi-Fi Scanning & Provisioning ---

  void _startWifiScan() {
    if (!widget.bridge.isConnected) {
      setState(() {
        _hasError = true;
        _statusMessage = "ESP32 BLE bağlantısı yok.";
      });
      return;
    }

    setState(() {
      _step = _ProvisioningStep.scanningWifi;
      _selectedSsid = null;
      _statusMessage = null;
      _hasError = false;
      _networks.clear();
    });

    widget.bridge.scanWifi().catchError((err) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusMessage = "Wi-Fi taraması başlatılamadı: $err";
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
      _statusMessage = "Kimlik bilgileri ve ayarlar ESP32'ye aktarılıyor...";
    });

    widget.bridge.connectWifi(
      _selectedSsid!,
      _passController.text.trim(),
      extraConfig: widget.extraConfig,
    );
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
                    if (_step == _ProvisioningStep.enteringPassword && !_isConnectingWifi)
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                        onPressed: () => setState(() {
                          _step = _ProvisioningStep.scanningWifi;
                          _selectedSsid = null;
                          _statusMessage = null;
                          _passController.clear();
                        }),
                      )
                    else if (_step == _ProvisioningStep.selectingBleDevice && !_isConnectingDevice)
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: "Tekrar Ara",
                        onPressed: _startBleDiscovery,
                      ),
                    Flexible(
                      child: Text(
                        _selectedSsid ?? widget.title,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_step == _ProvisioningStep.scanningWifi)
                IconButton(
                  onPressed: _startWifiScan,
                  icon: _networks.isEmpty
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: "Wi-Fi Yeniden Tara",
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

          // Dynamic Body based on active step
          if (_step == _ProvisioningStep.discoveringBle || _isConnectingDevice)
            _buildBleDiscoveryView(colorScheme)
          else if (_step == _ProvisioningStep.selectingBleDevice)
            _buildBleSelectionView(colorScheme)
          else if (_step == _ProvisioningStep.enteringPassword)
            _buildPasswordForm(colorScheme)
          else
            _buildNetworkList(colorScheme),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBleDiscoveryView(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _isConnectingDevice
                ? "ESP32 BLE bağlantısı kuruluyor..."
                : "Çevredeki ESP32 cihazları taranıyor...",
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildBleSelectionView(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            "Birden fazla ESP32 cihazı bulundu. Lütfen bağlanmak istediğinizi seçin:",
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _discoveredBleDevices.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final result = _discoveredBleDevices[index];
              final name = result.device.platformName.isNotEmpty
                  ? result.device.platformName
                  : "ESP32 Cihazı";
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.bluetooth),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
                subtitle: Text("${result.device.remoteId} (${result.rssi} dBm)"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _connectToBleDevice(result.device),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkList(ColorScheme colorScheme) {
    if (_networks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("ESP32 çevredeki Wi-Fi ağlarını tarıyor..."),
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
              _step = _ProvisioningStep.enteringPassword;
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
        if (widget.extraConfig != null && widget.extraConfig!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            "Ek yapılandırma aktarılacak (${widget.extraConfig!.keys.join(', ')})",
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
