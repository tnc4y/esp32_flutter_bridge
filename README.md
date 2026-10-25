<div align="center">

# ⚡ esp32-flutter-bridge

**Zero-boilerplate BLE Wi-Fi Provisioning & Bi-directional JSON Bridge between ESP32 and Flutter.**

[![PlatformIO](https://img.shields.io/badge/ESP32-PlatformIO%20%2F%20Arduino-orange?logo=espressif)](https://platformio.org/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

<p align="center">
  <i>Stop writing 500 lines of BLE state machines, byte chunking, and custom UUID handlers for every new IoT project. Drop in two files, get a ready-to-use Wi-Fi Provisioning UI and an MTU-agnostic JSON stream in 2 minutes.</i>
</p>

<!-- Place your 10-second demo GIF in assets/demo.gif -->
<img src="assets/demo.gif" alt="ESP32 Flutter Bridge Demo" width="650" />

</div>

---

## 🤔 Why does this exist?

Every time you start a new **ESP32 + Flutter** project, you face the same painful friction:

1. **Low-level BLE libraries** leave you dealing with raw `uint8_t` byte arrays, 20-byte MTU limits, and fragmented packets.
2. **Official Wi-Fi provisioning SDKs** are bloated, hard to customize, and often break across iOS and Android permission updates.
3. All you actually want is: **"Let the user pick a Wi-Fi network from a nice BottomSheet, save credentials to ESP32 NVS, and send/receive JSON."**

**`esp32-flutter-bridge`** solves this with a dead-simple **Newline-Delimited JSON (`\n`) stream** over a single BLE service.

---

## ✨ Features

* **🚀 2-Line ESP32 Setup:** Single-header C++ library (`EspFlutterBridge.h`). No complex state machines required.
* **📱 Drop-in Flutter BottomSheet UI:** Ready-to-use Material 3 Wi-Fi scanner & password modal (`showEspProvisioningSheet`).
* **📦 MTU-Agnostic Chunking:** Automatically splits and reassembles large JSON payloads across 20-byte or 256-byte MTU limits without data corruption.
* **💾 Built-in NVS Persistence:** Automatically saves verified Wi-Fi credentials to ESP32 flash memory (`Preferences`) and reconnects on boot without phone assistance.
* **🔄 Auto Re-Advertising:** Automatically restarts BLE advertising when the phone disconnects—no ESP32 reboot needed.
* **📡 Custom JSON Bridge:** Use the exact same BLE connection to stream sensor data or control GPIOs/relays after provisioning.

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
│   │   └── main.cpp                  # Example firmware with LED control & ping
│   ├── platformio.ini                # Pre-configured PlatformIO project file
│   └── library.json                  # PlatformIO package definition
├── flutter_client/                   # Example Flutter application
│   ├── lib/
│   │   ├── esp_ble_bridge.dart       # BLE & JSON Stream core class
│   │   ├── esp_provisioning_sheet.dart # Material 3 BottomSheet UI
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

    // 2. (Optional) Listen for custom JSON commands from Flutter
    Bridge.onJsonReceived([](JsonDocument& doc) {
        if (doc["cmd"] == "relay") {
            bool state = doc["val"];
            digitalWrite(2, state);
            Bridge.sendRawJson("{\"ev\":\"ack\",\"relay\":true}");
        }
    });
}

void loop() {
    Bridge.handle(); // Handles Wi-Fi scanning, provisioning & custom JSON
}
```

### 2. Flutter Side

Copy [`esp_ble_bridge.dart`](flutter_client/lib/esp_ble_bridge.dart) and [`esp_provisioning_sheet.dart`](flutter_client/lib/esp_provisioning_sheet.dart) into your `lib/` folder (requires [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus)).

```dart
import 'package:flutter/material.dart';
import 'esp_ble_bridge.dart';
import 'esp_provisioning_sheet.dart';

final bridge = EspBleBridge();

// 1. Connect to your ESP32 device
await bridge.connect(bluetoothDevice);

// 2. Open the Wi-Fi Provisioning BottomSheet in one line!
final String? deviceIp = await showEspProvisioningSheet(context, bridge);
if (deviceIp != null) {
  print("ESP32 is online at IP: $deviceIp");
}

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
| **Flutter $\rightarrow$ ESP32** | Connect & Save Wi-Fi | `{"cmd":"wifi","s":"Home_WiFi","p":"secret123"}\n` |
| **ESP32 $\rightarrow$ Flutter** | Provisioning Status | `{"ev":"status","s":"connected","ip":"192.168.1.42"}\n` |
| **Bi-directional** | Custom User Data | `{"cmd":"any_custom_key","temp":24.5}\n` |

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
