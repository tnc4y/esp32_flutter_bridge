#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>
#include <functional>
#include <cstdarg>

#define EFB_SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define EFB_CHAR_RX_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define EFB_CHAR_TX_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

/**
 * @brief Zero-boilerplate BLE Wi-Fi Provisioning & Bi-directional JSON Bridge
 *        between ESP32 and Flutter.
 */
class EspFlutterBridge : public BLEServerCallbacks, public BLECharacteristicCallbacks {
public:
    using JsonCallback   = std::function<void(JsonDocument&)>;
    using ConfigCallback = std::function<void(JsonObject&)>;

    /**
     * @brief Initialize BLE stack, advertising, and attempt auto-connection to saved Wi-Fi.
     * @param deviceName Bluetooth LE advertised device name.
     * @param autoConnectSavedWifi Whether to automatically connect to NVS-saved credentials on boot.
     */
    void begin(const char* deviceName = "ESP32_Bridge", bool autoConnectSavedWifi = true) {
        WiFi.mode(WIFI_STA);

        // Attempt connecting to saved credentials if available in NVS
        if (autoConnectSavedWifi) {
            _prefs.begin("efb_wifi", true);
            String savedSsid = _prefs.getString("ssid", "");
            String savedPass = _prefs.getString("pass", "");
            _prefs.end();

            if (savedSsid.length() > 0) {
                WiFi.begin(savedSsid.c_str(), savedPass.c_str());
            }
        }

        // Initialize BLE Stack
        BLEDevice::init(deviceName);
        BLEDevice::setMTU(256);
        _pServer = BLEDevice::createServer();
        _pServer->setCallbacks(this);

        BLEService *pService = _pServer->createService(EFB_SERVICE_UUID);

        // TX Characteristic (ESP32 -> Flutter Notify)
        _pTxChar = pService->createCharacteristic(
            EFB_CHAR_TX_UUID,
            BLECharacteristic::PROPERTY_NOTIFY
        );
        _pTxChar->addDescriptor(new BLE2902());

        // RX Characteristic (Flutter -> ESP32 Write)
        BLECharacteristic *pRxChar = pService->createCharacteristic(
            EFB_CHAR_RX_UUID,
            BLECharacteristic::PROPERTY_WRITE
        );
        pRxChar->setCallbacks(this);

        pService->start();

        // Start Advertising with service UUID & mobile optimization flags
        BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
        pAdvertising->addServiceUUID(EFB_SERVICE_UUID);
        pAdvertising->setScanResponse(true);
        pAdvertising->setMinPreferred(0x06); // Assists iOS connection stability
        pAdvertising->setMinPreferred(0x12);
        BLEDevice::startAdvertising();
    }

    /**
     * @brief Main processing loop. Must be called repeatedly inside Arduino loop().
     */
    void handle() {
        while (true) {
            int idx = _rxBuffer.indexOf('\n');
            if (idx < 0) break;

            String line = _rxBuffer.substring(0, idx);
            _rxBuffer = _rxBuffer.substring(idx + 1);
            line.trim();

            if (line.length() > 0) {
                _processCommand(line);
            }
        }
        _commandReady = false;
    }

    /**
     * @brief Register a callback for custom application JSON commands.
     * @param cb Callback function receiving parsed ArduinoJson JsonDocument.
     */
    void onJsonReceived(JsonCallback cb) {
        _userCallback = cb;
    }

    /**
     * @brief Register a callback triggered when custom extraConfig parameters arrive during provisioning.
     * @param cb Callback receiving JsonObject containing extra configuration key-values.
     */
    void onConfigReceived(ConfigCallback cb) {
        _configCallback = cb;
    }

    /**
     * @brief Retrieve a string value from NVS saved during provisioning extraConfig.
     */
    String getConfig(const char* key, const String& defaultValue = "") {
        _prefs.begin("efb_cfg", true);
        String val = _prefs.getString(key, defaultValue);
        _prefs.end();
        return val;
    }

    /**
     * @brief Save or update a custom string configuration in NVS.
     */
    void setConfig(const char* key, const String& value) {
        _prefs.begin("efb_cfg", false);
        _prefs.putString(key, value);
        _prefs.end();
    }

    /**
     * @brief Serialize and send an ArduinoJson JsonDocument to Flutter.
     * @param doc JsonDocument instance.
     */
    void sendJson(const JsonDocument& doc) {
        String out;
        serializeJson(doc, out);
        sendRawJson(out);
    }

    /**
     * @brief Send a raw JSON string to Flutter split into MTU-safe chunks.
     *        Appends newline separator automatically.
     * @param jsonStr Raw JSON string.
     */
    void sendRawJson(const String& jsonStr) {
        if (!_deviceConnected || !_pTxChar) return;

        String payload = jsonStr;
        if (!payload.endsWith("\n")) {
            payload += "\n";
        }

        int len = payload.length();
        const int chunkSize = 180;

        for (int i = 0; i < len; i += chunkSize) {
            int currentChunk = (i + chunkSize < len) ? chunkSize : (len - i);
            String chunk = payload.substring(i, i + currentChunk);
            _pTxChar->setValue((uint8_t*)chunk.c_str(), chunk.length());
            _pTxChar->notify();
            delay(12); // Give BLE stack time to dispatch notifications
        }
    }

    /**
     * @brief Sends a real-time log message to Flutter's live debug console over BLE
     *        and echoes it to hardware Serial.
     * @param msg Log message string.
     */
    void log(const String& msg) {
        Serial.println(msg);
        if (_deviceConnected && _pTxChar) {
            JsonDocument doc;
            doc["ev"] = "log";
            doc["msg"] = msg;
            sendJson(doc);
        }
    }

    /**
     * @brief Formatted log output (printf-style) sent over BLE and Serial.
     */
    void logf(const char* format, ...) {
        char buffer[256];
        va_list args;
        va_start(args, format);
        vsnprintf(buffer, sizeof(buffer), format, args);
        va_end(args);
        log(String(buffer));
    }

    /**
     * @brief Clear saved Wi-Fi credentials from NVS.
     */
    void clearSavedWifi() {
        _prefs.begin("efb_wifi", false);
        _prefs.clear();
        _prefs.end();
    }

    /**
     * @brief Clear saved custom configuration from NVS.
     */
    void clearSavedConfig() {
        _prefs.begin("efb_cfg", false);
        _prefs.clear();
        _prefs.end();
    }

    bool isBleConnected() const { return _deviceConnected; }
    bool isWifiConnected() const { return WiFi.status() == WL_CONNECTED; }
    String getIpAddress() const { return WiFi.localIP().toString(); }

    // --- BLE Callbacks ---
    void onConnect(BLEServer* pServer) override {
        _deviceConnected = true;
    }

    void onDisconnect(BLEServer* pServer) override {
        _deviceConnected = false;
        delay(200);
        pServer->startAdvertising(); // Auto re-advertising on disconnect
    }

    void onWrite(BLECharacteristic *pChar) override {
        String val = pChar->getValue().c_str();
        _rxBuffer += val;
        if (val.indexOf('\n') >= 0) {
            _commandReady = true;
        }
    }

private:
    BLEServer* _pServer = nullptr;
    BLECharacteristic* _pTxChar = nullptr;
    Preferences _prefs;
    String _rxBuffer = "";
    volatile bool _commandReady = false;
    bool _deviceConnected = false;
    JsonCallback _userCallback = nullptr;
    ConfigCallback _configCallback = nullptr;

    void _processCommand(const String& jsonRaw) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, jsonRaw);
        if (err) {
            return;
        }

        String cmd = doc["cmd"] | "";

        // 1. Built-in Command: Wi-Fi Scan
        if (cmd == "scan") {
            int16_t n = WiFi.scanNetworks();
            JsonDocument res;
            res["ev"] = "nets";
            JsonArray list = res["list"].to<JsonArray>();

            int count = (n < 12) ? n : 12;
            for (int i = 0; i < count; i++) {
                JsonObject net = list.add<JsonObject>();
                net["s"] = WiFi.SSID(i);
                net["r"] = WiFi.RSSI(i);
            }

            sendJson(res);
            WiFi.scanDelete();
        }
        // 2. Built-in Command: Wi-Fi Connect, Save Credentials & Extra Config
        else if (cmd == "wifi") {
            String ssid = doc["s"] | "";
            String pass = doc["p"] | "";

            // Save custom extraConfig payload if present (e.g. MQTT host, user token, device ID)
            if (doc["extra"].is<JsonObject>()) {
                JsonObject extra = doc["extra"].as<JsonObject>();
                _prefs.begin("efb_cfg", false);
                for (JsonPair kv : extra) {
                    _prefs.putString(kv.key().c_str(), kv.value().as<String>());
                }
                _prefs.end();

                if (_configCallback) {
                    _configCallback(extra);
                }
            }

            WiFi.disconnect();
            WiFi.begin(ssid.c_str(), pass.c_str());
            sendRawJson("{\"ev\":\"status\",\"s\":\"connecting\"}");

            int tries = 0;
            while (WiFi.status() != WL_CONNECTED && tries < 20) {
                delay(500);
                tries++;
            }

            if (WiFi.status() == WL_CONNECTED) {
                // Save verified credentials to NVS
                _prefs.begin("efb_wifi", false);
                _prefs.putString("ssid", ssid);
                _prefs.putString("pass", pass);
                _prefs.end();

                sendRawJson("{\"ev\":\"status\",\"s\":\"connected\",\"ip\":\"" + WiFi.localIP().toString() + "\"}");
            } else {
                sendRawJson("{\"ev\":\"status\",\"s\":\"failed\"}");
            }
        }
        // 3. Built-in Command: Device Diagnostics (Info)
        else if (cmd == "info") {
            JsonDocument res;
            res["ev"] = "info";
            res["wifi"] = (WiFi.status() == WL_CONNECTED);
            res["ssid"] = WiFi.SSID();
            res["ip"] = WiFi.localIP().toString();
            res["rssi"] = WiFi.RSSI();
            res["heap"] = ESP.getFreeHeap();
            res["uptime"] = millis();
            sendJson(res);
        }
        // 4. Built-in Command: Factory Reset Wi-Fi & Configuration
        else if (cmd == "reset_wifi") {
            clearSavedWifi();
            clearSavedConfig();
            WiFi.disconnect(true);
            sendRawJson("{\"ev\":\"status\",\"s\":\"reset\"}");
        }
        // 5. Custom Developer Commands (Sensors, relays, telemetry, etc.)
        else {
            if (_userCallback) {
                _userCallback(doc);
            }
        }
    }
};

// Global default bridge instance for easy drop-in usage
#if __cplusplus >= 201703L
inline EspFlutterBridge Bridge;
#else
static EspFlutterBridge Bridge;
#endif
