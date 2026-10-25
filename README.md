<div align="center">

# ⚡ esp32-flutter-bridge

**Zero-boilerplate BLE Wi-Fi Provisioning & Bi-directional JSON Bridge between ESP32 and Flutter.**

[![PlatformIO](https://img.shields.io/badge/ESP32-PlatformIO%20%2F%20Arduino-orange?logo=espressif)](https://platformio.org/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

<p align="center">
  <i>Stop writing 500 lines of BLE state machines, byte chunking, and custom UUID handlers for every new IoT project. Drop in two files, get a ready-to-use Wi-Fi Provisioning UI, auto-discovery, live debug logs, and an MTU-agnostic JSON stream in 2 minutes.</i>
</p>

<!-- Place your 10-second demo GIF in assets/demo.gif -->
<img src="assets/demo.gif" alt="ESP32 Flutter Bridge Demo" width="650" />

</div>

---

## 🤔 Why does this exist?

Every time you start a new **ESP32 + Flutter** project, you face the same painful friction:

1. **Low-level BLE libraries** leave you dealing with raw `uint8_t` byte arrays, 20-byte MTU limits, and fragmented packets.
2. **Official Wi-Fi provisioning SDKs** are bloated, hard to customize, and break across mobile OS permission updates.
3. **No wireless serial logs:** When your ESP32 is deployed in the field without a USB cable, debugging feels blind.
4. All you actually want is: **"Let the user pick a Wi-Fi network, pass an MQTT broker or user token, save credentials to NVS, and send/receive JSON."**

**`esp32-flutter-bridge`** solves this with a dead-simple **Newline-Delimited JSON (`\n`) stream** over a single BLE service.

---

## ✨ Features

* **🚀 2-Line ESP32 Setup:** Single-header C++ library (`EspFlutterBridge.h`). No complex callbacks required.
* **🪄 Zero-Touch Auto-Discovery:** Open the BottomSheet without connecting first; if 1 ESP32 is found nearby, it connects automatically and opens the Wi-Fi list instantly!
* **📦 Custom Provisioning Payload (`extraConfig`):** Send MQTT endpoints, auth tokens, or device names alongside Wi-Fi credentials in one shot; ESP32 saves them to NVS automatically.
* **📟 Wireless Live Debug Console (`Bridge.log`):** Call `Bridge.log("Sensor ready")` in C++; view colorized, real-time logs right on your phone without USB cables.
* **🩺 Diagnostics & Factory Reset:** Built-in `{"cmd":"info"}` (Free RAM, Wi-Fi SSID, RSSI, uptime) and `{"cmd":"reset_wifi"}` for one-click factory reset.
* **📦 MTU-Agnostic Chunking:** Automatically splits and reassembles large payloads across 20-byte or 256-byte MTU limits without data corruption.
* **💾 Built-in NVS Persistence:** Automatically saves verified Wi-Fi credentials to ESP32 flash memory (`Preferences`) and reconnects on boot.
* **🔄 Auto Re-Advertising:** Automatically restarts BLE advertising when the phone disconnects—no ESP32 reboot needed.

---

## 📁 Repository Structure

```plaintext
esp32_flutter_bridge/
├── assets/
│   ├── demo.gif                      # Showcase GIF for GitHub README
│   └── README.md
├── firmware_esp32/                   # PlatformIO / Arduino project
│   ├── include/
│   │   └── EspFlutterBridge.h        # Single-header C++ library
│   ├── src/
│   │   └── main.cpp                  # Example firmware with LED control & Bridge.log
│   ├── platformio.ini                # Pre-configured PlatformIO project file
│   └── library.json                  # PlatformIO package definition
├── flutter_client/                   # Example Flutter application
│   ├── lib/
│   │   ├── esp_ble_bridge.dart       # BLE & JSON Stream core class
│   │   ├── esp_provisioning_sheet.dart # Material 3 BottomSheet UI (Auto-Discovery)
│   │   ├── esp_debug_console.dart    # Live Remote Serial/Log Console Widget
│   │   └── main.dart                 # Full-featured interactive demo app
│   ├── android/                      # Pre-configured Bluetooth permissions
│   ├── ios/                          # Pre-configured Info.plist permissions
│   └── pubspec.yaml
├── .gitignore
├── LICENSE                           # MIT License
└── README.md
```

---

## ⚡ Quick Start (Under 2 Minutes)

### 1. ESP32 Side (Arduino / PlatformIO)

Copy [`EspFlutterBridge.h`](firmware_esp32/include/EspFlutterBridge.h) into your project's `include/` folder and add `bblanchon/ArduinoJson @ ^7.0.0` to your dependencies.

```cpp
#include <Arduino.h>
#include "EspFlutterBridge.h"

void setup() {
    Serial.begin(115200);

    // 1. Starts BLE & auto-connects to saved Wi-Fi if available
    Bridge.begin("My_Smart_Device");
    Bridge.log("Device booted and BLE advertising active!");

    // 2. Read saved custom config from NVS (e.g. MQTT broker or token)
    String mqttBroker = Bridge.getConfig("mqtt_host", "default.broker.io");

    // 3. Listen for custom provisioning parameters sent during Wi-Fi setup
    Bridge.onConfigReceived([](JsonObject& cfg) {
        if (cfg["mqtt_host"].is<const char*>()) {
            Bridge.logf("Configured MQTT: %s", cfg["mqtt_host"].as<const char*>());
        }
    });

    // 4. (Optional) Custom JSON commands from Flutter
    Bridge.onJsonReceived([](JsonDocument& doc) {
        if (doc["cmd"] == "relay") {
            bool state = doc["val"];
            digitalWrite(2, state);
            Bridge.sendRawJson("{\"ev\":\"ack\",\"relay\":true}");
        }
    });
}

void loop() {
    Bridge.handle(); // Keeps BLE, provisioning, and logging alive
}
```

### 2. Flutter Side

Copy [`esp_ble_bridge.dart`](flutter_client/lib/esp_ble_bridge.dart), [`esp_provisioning_sheet.dart`](flutter_client/lib/esp_provisioning_sheet.dart), and [`esp_debug_console.dart`](flutter_client/lib/esp_debug_console.dart) into your `lib/` folder (requires [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus)).

```dart
import 'package:flutter/material.dart';
import 'esp_ble_bridge.dart';
import 'esp_provisioning_sheet.dart';
import 'esp_debug_console.dart';

final bridge = EspBleBridge();

// 1. One-line Wi-Fi Provisioning with Auto-Discovery & Custom Payload!
// If not connected, it discovers the ESP32 automatically, pairs, and opens the Wi-Fi list.
final String? ip = await showEspProvisioningSheet(
  context,
  bridge,
  extraConfig: {
    "mqtt_host": "broker.emqx.io",
    "device_token": "usr_alpha_9981",
  },
);

if (ip != null) {
  print("ESP32 is online at IP: $ip");
}

// 2. Open live wireless debug console anytime
showEspDebugModal(context, bridge);

// 3. Send custom JSON anytime (automatically chunked & newline-delimited)
await bridge.sendJson({"cmd": "relay", "val": true});

// 4. Listen to incoming JSON stream from ESP32
bridge.onJsonReceived.listen((Map<String, dynamic> data) {
  print("Received from ESP32: $data");
});
```

---

## 🔌 How the Protocol Works

Instead of complex binary headers and CRC framing, this bridge uses Nordic UART-style characteristics with **newline-delimited JSON (`\n`)**:

* **Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
* **RX Characteristic (`Flutter -> ESP32 | WRITE`):** `beb5483e-36e1-4688-b7f5-ea07361b26a8`
* **TX Characteristic (`ESP32 -> Flutter | NOTIFY`):** `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

### Message Formats

| Direction | Action | Payload Format |
| :--- | :--- | :--- |
| **Flutter $\rightarrow$ ESP32** | Scan Wi-Fi Networks | `{"cmd":"scan"}\n` |
| **ESP32 $\rightarrow$ Flutter** | Network List Response | `{"ev":"nets","list":[{"s":"Home_WiFi","r":-52}]}\n` |
| **Flutter $\rightarrow$ ESP32** | Connect Wi-Fi & Extra Config | `{"cmd":"wifi","s":"Home_WiFi","p":"secret123","extra":{"mqtt_host":"..."}}\n` |
| **ESP32 $\rightarrow$ Flutter** | Provisioning Status | `{"ev":"status","s":"connected","ip":"192.168.1.42"}\n` |
| **Flutter $\rightarrow$ ESP32** | Request Diagnostics | `{"cmd":"info"}\n` |
| **ESP32 $\rightarrow$ Flutter** | Diagnostics Status | `{"ev":"info","wifi":true,"ssid":"Home_WiFi","ip":"192.168.1.42","rssi":-54,"heap":198240,"uptime":34200}\n` |
| **Flutter $\rightarrow$ ESP32** | Factory Reset Wi-Fi & Config | `{"cmd":"reset_wifi"}\n` |
| **ESP32 $\rightarrow$ Flutter** | Live Remote Log | `{"ev":"log","msg":"Sensor reading: 24.2C"}\n` |
| **Bi-directional** | Custom User Data | `{"cmd":"any_custom_key","temp":24.5}\n` |

---

## 🗺️ Roadmap

- [x] **v0.1:** Core BLE Newline-Delimited JSON streaming engine & MTU chunker.
- [x] **v0.2:** Zero-Touch Auto-Discovery in BottomSheet (single ESP32 auto-connect).
- [x] **v0.2:** Custom Provisioning Payload (`extraConfig` persisted in NVS).
- [x] **v0.2:** Wireless Live Debug Console (`Bridge.log` & `EspDebugConsole`).
- [x] **v0.2:** Device Diagnostics (`{"cmd":"info"}`) and Factory Reset (`{"cmd":"reset_wifi"}`).
- [ ] **v0.3:** Web Bluetooth fallback support (Provision ESP32 directly via Chrome/Web without mobile apps).
- [ ] **v0.3:** Optional End-to-End Encryption (AES-GCM pre-shared key for enterprise environments).
- [ ] **v0.4:** Publish to PlatformIO Registry and Arduino Library Manager.

---

## 🛠️ Required Permissions

### Android (`AndroidManifest.xml`)
Add the following to your `android/app/src/main/AndroidManifest.xml` (already configured in `flutter_client/`):

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

### iOS (`Info.plist`)
Add the following keys to your `ios/Runner/Info.plist` (already configured in `flutter_client/`):

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app requires Bluetooth Low Energy access to connect and provision your ESP32 device.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app requires Bluetooth Low Energy access to communicate with your ESP32 device.</string>
```

---

## 🤝 Contributing & Feedback

Contributions, feature requests, and bug reports are welcome!
If this project saved you time and headaches dealing with BLE and provisioning, please consider giving the repository a ⭐!
