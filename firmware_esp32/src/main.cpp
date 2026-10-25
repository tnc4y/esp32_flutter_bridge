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
    Serial.println("EspFlutterBridge started. Waiting for Flutter connection...");

    // 2. (Optional) Register custom JSON command handler
    Bridge.onJsonReceived([](JsonDocument& doc) {
        String cmd = doc["cmd"] | "";

        if (cmd == "led") {
            bool state = doc["val"] | false;
            digitalWrite(LED_PIN, state ? HIGH : LOW);
            Serial.printf("LED toggled to: %s\n", state ? "ON" : "OFF");

            // Send acknowledgment back to Flutter
            Bridge.sendRawJson(String("{\"ev\":\"ack\",\"cmd\":\"led\",\"state\":") + (state ? "true" : "false") + "}");
        }
        else if (cmd == "ping") {
            Bridge.sendRawJson("{\"ev\":\"pong\",\"uptime\":" + String(millis()) + "}");
        }
    });
}

void loop() {
    // 3. Keep the bridge running
    Bridge.handle();
}
