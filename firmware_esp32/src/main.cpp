#include <Arduino.h>
#include "EspFlutterBridge.h"

// Built-in LED on most ESP32 boards is GPIO 2
#define LED_PIN 2

void setup() {
    Serial.begin(115200);
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);

    // 1. Start BLE advertising & auto-connect to saved Wi-Fi if present
    Bridge.begin("ESP32_Bridge");
    Bridge.log("EspFlutterBridge initialized. BLE advertising active.");

    // Check if custom config was previously stored (e.g. MQTT broker or auth token)
    String mqttHost = Bridge.getConfig("mqtt_host", "none");
    if (mqttHost != "none") {
        Bridge.logf("Loaded saved MQTT Host: %s", mqttHost.c_str());
    }

    // 2. Listen for custom provisioning config (sent via extraConfig from Flutter)
    Bridge.onConfigReceived([](JsonObject& cfg) {
        Bridge.log("New extraConfig received from Flutter!");
        if (cfg["mqtt_host"].is<const char*>()) {
            Bridge.logf("Configured MQTT Host: %s", cfg["mqtt_host"].as<const char*>());
        }
        if (cfg["device_token"].is<const char*>()) {
            Bridge.logf("Configured Device Token: %s", cfg["device_token"].as<const char*>());
        }
    });

    // 3. (Optional) Register custom JSON command handler
    Bridge.onJsonReceived([](JsonDocument& doc) {
        String cmd = doc["cmd"] | "";

        if (cmd == "led") {
            bool state = doc["val"] | false;
            digitalWrite(LED_PIN, state ? HIGH : LOW);
            Bridge.logf("LED switched %s via Flutter command", state ? "ON" : "OFF");

            // Send acknowledgment back to Flutter
            Bridge.sendRawJson(String("{\"ev\":\"ack\",\"cmd\":\"led\",\"state\":") + (state ? "true" : "false") + "}");
        }
        else if (cmd == "ping") {
            Bridge.sendRawJson("{\"ev\":\"pong\",\"uptime\":" + String(millis()) + "}");
        }
    });
}

void loop() {
    // 4. Keep the bridge running
    Bridge.handle();
}
