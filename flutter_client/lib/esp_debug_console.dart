import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'esp_ble_bridge.dart';

/// Opens the ESP32 Live Debug Console as a modal bottom sheet.
Future<void> showEspDebugModal(
  BuildContext context,
  EspBleBridge bridge, {
  String title = "ESP32 Canlı Hata Ayıklama Konsolu",
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.75,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: EspDebugConsole(
          bridge: bridge,
          title: title,
        ),
      ),
    ),
  );
}

/// A ready-to-use real-time remote serial/log viewer widget for ESP32 over BLE.
class EspDebugConsole extends StatefulWidget {
  final EspBleBridge bridge;
  final String title;
  final int maxLines;
  final bool showAppBar;

  const EspDebugConsole({
    super.key,
    required this.bridge,
    this.title = "ESP32 Canlı Loglar",
    this.maxLines = 200,
    this.showAppBar = true,
  });

  @override
  State<EspDebugConsole> createState() => _EspDebugConsoleState();
}

class _EspDebugConsoleState extends State<EspDebugConsole> {
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _logSub;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _logSub = widget.bridge.onLogReceived.listen((msg) {
      if (!mounted) return;
      setState(() {
        final timestamp = _formatTimestamp(DateTime.now());
        _logs.add("[$timestamp] $msg");
        if (_logs.length > widget.maxLines) {
          _logs.removeAt(0);
        }
      });

      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = (dt.millisecond ~/ 10).toString().padLeft(2, '0');
    return "$h:$m:$s.$ms";
  }

  void _copyAllLogs() {
    if (_logs.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _logs.join("\n")));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Tüm loglar panoya kopyalandı!"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Color _getLineColor(String line) {
    final lower = line.toLowerCase();
    if (lower.contains("error") || lower.contains("fail") || lower.contains("err")) {
      return const Color(0xFFFF5252); // Red accent
    }
    if (lower.contains("warn")) {
      return const Color(0xFFFFD740); // Amber accent
    }
    if (lower.contains("wifi") || lower.contains("connected") || lower.contains("online")) {
      return const Color(0xFF69F0AE); // Green accent
    }
    if (lower.contains("ble") || lower.contains("bridge") || lower.contains("init")) {
      return const Color(0xFF40C4FF); // Cyan accent
    }
    return const Color(0xFFE0E0E0);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Top Action Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.terminal, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(
                  _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                  color: _autoScroll ? colorScheme.primary : colorScheme.outline,
                ),
                tooltip: _autoScroll ? "Otomatik Kaydırma Açık" : "Kaydırma Duraklatıldı",
                onPressed: () => setState(() => _autoScroll = !_autoScroll),
              ),
              IconButton(
                icon: const Icon(Icons.copy_all, size: 20),
                tooltip: "Logları Kopyala",
                onPressed: _logs.isEmpty ? null : _copyAllLogs,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: "Temizle",
                onPressed: _logs.isEmpty ? null : () => setState(() => _logs.clear()),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Terminal Console Area
        Expanded(
          child: Container(
            color: const Color(0xFF121212),
            child: _logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.sensors, color: Colors.white24, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          widget.bridge.isConnected
                              ? "ESP32'den log bekleniyor...\n(Bridge.log() çağrıları burada görünür)"
                              : "ESP32 bağlı değil.",
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final line = _logs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: SelectableText(
                            line,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.35,
                              color: _getLineColor(line),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
