#include <Wire.h>
#include <WiFi.h>
#include <Firebase_ESP_Client.h>
#include "MAX30105.h"
#include "spo2_algorithm.h"
#include <OneWire.h>
#include <DallasTemperature.h>
#include <MPU6050.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>

// ── WiFi and Firebase credentials ────────────────────────────────────────────
#include "secrets.h"

// ── Pins ──────────────────────────────────────────────────────────────────────
#define ONE_WIRE_BUS 4
#define GLUCOSE_PIN  34

// ── OLED ──────────────────────────────────────────────────────────────────────
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_RESET    -1
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// ── Sensors ───────────────────────────────────────────────────────────────────
MAX30105 particleSensor;
OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature tempSensor(&oneWire);
MPU6050 mpu;

// ── Firebase ──────────────────────────────────────────────────────────────────
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

// ── MAX30102 buffers ──────────────────────────────────────────────────────────
uint32_t irBuffer[100];
uint32_t redBuffer[100];
int32_t  spo2;
int8_t   validSPO2;
int32_t  heartRate;
int8_t   validHeartRate;

// ── HRV calculation ───────────────────────────────────────────────────────────
#define RR_BUFFER_SIZE 20
float rrBuffer[RR_BUFFER_SIZE];
int   rrCount = 0;
long  lastPeakTime = 0;
long  lastIR = 0;
bool  rising = false;

// ── Smoothing ─────────────────────────────────────────────────────────────────
float smoothHR   = 0;
float smoothSPO2 = 0;
float smoothHRV  = 0;
int   validCount = 0;

// ── Timing ────────────────────────────────────────────────────────────────────
unsigned long lastSendTime    = 0;
unsigned long lastTempTime    = 0;
float         currentTemp     = 0;
const long    SEND_INTERVAL   = 5000;
const long    TEMP_INTERVAL   = 3000;

// ══════════════════════════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  delay(1000);

  // OLED init
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED not found");
  }
  oledShow("AI Health Monitor", "Initializing...", "", "", "", "");

  // MAX30102 init
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found!");
    oledShow("ERROR", "MAX30102", "Check wiring", "", "", "");
    while (1);
  }
  byte ledBrightness = 60;
  byte sampleAverage = 4;
  byte ledMode       = 2;
  int  sampleRate    = 100;
  int  pulseWidth    = 411;
  int  adcRange      = 4096;
  particleSensor.setup(ledBrightness, sampleAverage, ledMode,
                       sampleRate, pulseWidth, adcRange);
  particleSensor.setPulseAmplitudeRed(0x3F);
  particleSensor.setPulseAmplitudeIR(0x3F);
  particleSensor.setPulseAmplitudeGreen(0);
  Serial.println("MAX30102 ready");

  // DS18B20 init
  tempSensor.begin();
  Serial.println("DS18B20 ready");

  // MPU6050 init
  mpu.initialize();
  Serial.println("MPU6050 ready");

  // Read initial 100 samples to fill buffer
  for (byte i = 0; i < 100; i++) {
    while (particleSensor.available() == false)
      particleSensor.check();
    redBuffer[i] = particleSensor.getRed();
    irBuffer[i]  = particleSensor.getIR();
    particleSensor.nextSample();
  }
  Serial.println("Buffer filled");

  // WiFi connect
  oledShow("Connecting WiFi", WIFI_SSID, "", "", "", "");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 30) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi: " + WiFi.localIP().toString());
    oledShow("WiFi Connected", WiFi.localIP().toString().c_str(), "", "", "", "");
  } else {
    Serial.println("\nWiFi failed");
    oledShow("WiFi FAILED", "No internet", "", "", "", "");
  }
  delay(1000);

  // Firebase init
  config.database_url = FIREBASE_HOST;
  config.signer.tokens.legacy_token = FIREBASE_AUTH;
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);
  Serial.println("Firebase ready");
  oledShow("System Ready", "Place finger on", "MAX30102 sensor", "", "", "");
  delay(2000);
}

// ══════════════════════════════════════════════════════════════════════════════
void loop() {

  // ── Shift buffer and read 25 new samples ───────────────────────────────────
  for (byte i = 25; i < 100; i++) {
    redBuffer[i-25] = redBuffer[i];
    irBuffer[i-25]  = irBuffer[i];
  }
  for (byte i = 75; i < 100; i++) {
    while (particleSensor.available() == false)
      particleSensor.check();
    redBuffer[i] = particleSensor.getRed();
    irBuffer[i]  = particleSensor.getIR();
    particleSensor.nextSample();
  }

  // ── Check finger presence ──────────────────────────────────────────────────
  long irValue = irBuffer[99];
  bool fingerPresent = (irValue > 50000);

  if (!fingerPresent) {
    Serial.println("No finger detected");
    oledShow("Place finger on", "MAX30102 sensor", "", "", "", "");
    smoothHR   = 0;
    smoothSPO2 = 0;
    smoothHRV  = 0;
    validCount = 0;
    rrCount    = 0;
    return;
  }

  // ── Calculate HR and SpO2 ──────────────────────────────────────────────────
  maxim_heart_rate_and_oxygen_saturation(
    irBuffer, 100, redBuffer,
    &spo2, &validSPO2, &heartRate, &validHeartRate
  );

  // ── Validate and smooth HR ─────────────────────────────────────────────────
  // Only accept HR in clinically valid range 40-160 BPM
  if (validHeartRate && heartRate >= 40 && heartRate <= 160) {
    float correctedHR = heartRate;
    // Correct double-peak: if reading is above 100, halve it
    if (correctedHR > 100 && correctedHR <= 160)
      correctedHR = correctedHR / 2.0;
    // Only accept corrected value if in normal range
    if (correctedHR >= 40 && correctedHR <= 100) {
      if (smoothHR == 0)
        smoothHR = correctedHR;
      else
        smoothHR = 0.7 * smoothHR + 0.3 * correctedHR;
    }
  }

  // ── Validate and smooth SpO2 ───────────────────────────────────────────────
  // Only accept SpO2 in clinically valid range 70-100%
  if (validSPO2 && spo2 >= 70 && spo2 <= 100) {
    if (smoothSPO2 == 0)
      smoothSPO2 = spo2;
    else
      smoothSPO2 = 0.7 * smoothSPO2 + 0.3 * spo2;
  }

  // ── Compute HRV from smoothed HR ───────────────────────────────────────────
  // Estimate R-R interval from smoothed HR
  if (smoothHR > 0) {
    float rr = 60000.0 / smoothHR; // R-R in ms
    if (rrCount < RR_BUFFER_SIZE) {
      rrBuffer[rrCount++] = rr;
    } else {
      // Shift buffer
      for (int i = 1; i < RR_BUFFER_SIZE; i++)
        rrBuffer[i-1] = rrBuffer[i];
      rrBuffer[RR_BUFFER_SIZE-1] = rr;

      // Compute RMSSD
      float sumSqDiff = 0;
      for (int i = 1; i < RR_BUFFER_SIZE; i++) {
        float diff = rrBuffer[i] - rrBuffer[i-1];
        sumSqDiff += diff * diff;
      }
      float rmssd = sqrt(sumSqDiff / (RR_BUFFER_SIZE - 1));

      // Only accept physiologically plausible HRV (5-100 ms)
      if (rmssd >= 5 && rmssd <= 100)
        smoothHRV = 0.8 * smoothHRV + 0.2 * rmssd;
    }
  }

  // ── Read temperature every 3 seconds ──────────────────────────────────────
  if (millis() - lastTempTime >= TEMP_INTERVAL) {
    lastTempTime = millis();
    tempSensor.requestTemperatures();
    float t = tempSensor.getTempCByIndex(0);
    if (t != -127.0 && t > 0)
      currentTemp = t;
  }

  // ── Read MPU6050 activity ──────────────────────────────────────────────────
  int16_t ax, ay, az, gx, gy, gz;
  mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);
  float ax_g = ax / 16384.0;
  float ay_g = ay / 16384.0;
  float az_g = az / 16384.0;
  float magnitude = sqrt(ax_g*ax_g + ay_g*ay_g + az_g*az_g);
  float activity  = constrain(magnitude - 1.0, 0, 5.0);

  // ── Read sweat glucose from ADC ────────────────────────────────────────────
  int   raw     = analogRead(GLUCOSE_PIN);
  float voltage = raw * (3.3 / 4095.0);
  float glucose = constrain((voltage - 0.2) / 2.1, 0, 5.0);

  // ── Print to Serial ────────────────────────────────────────────────────────
  Serial.print("HR=");   Serial.print(smoothHR, 1);
  Serial.print(" SpO2=");Serial.print(smoothSPO2, 1);
  Serial.print(" HRV="); Serial.print(smoothHRV, 1);
  Serial.print(" Temp=");Serial.print(currentTemp, 1);
  Serial.print(" Act="); Serial.print(activity, 2);
  Serial.print(" Glu="); Serial.println(glucose, 3);

  // ── Update OLED ────────────────────────────────────────────────────────────
  String l1 = "HR:   " + String(smoothHR, 0)   + " BPM";
  String l2 = "SpO2: " + String(smoothSPO2, 0) + " %";
  String l3 = "HRV:  " + String(smoothHRV, 1)  + " ms";
  String l4 = "Temp: " + String(currentTemp, 1) + " C";
  String l5 = "Act:  " + String(activity, 2)    + " g";
  String l6 = "Glu:  " + String(glucose, 3)     + " mmol";
  oledShow(l1.c_str(), l2.c_str(), l3.c_str(),
           l4.c_str(), l5.c_str(), l6.c_str());

  // ── Send to Firebase every 5 seconds ──────────────────────────────────────
  if (millis() - lastSendTime >= SEND_INTERVAL) {
    lastSendTime = millis();

    if (Firebase.ready()) {
      FirebaseJson json;
      json.set("hr",            smoothHR);
      json.set("spo2",          smoothSPO2);
      json.set("hrv_rmssd",     smoothHRV);
      json.set("temp",          currentTemp);
      json.set("activity",      activity);
      json.set("sweat_glucose", glucose);
      json.set("patient_id",    "patient001");

      if (Firebase.RTDB.setJSON(&fbdo, "/patient001/vitals", &json))
        Serial.println("Firebase: OK");
      else
        Serial.println("Firebase error: " + fbdo.errorReason());
    }
  }
}

// ── OLED display helper ────────────────────────────────────────────────────────
void oledShow(const char* l1, const char* l2, const char* l3,
              const char* l4, const char* l5, const char* l6) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);  display.println(l1);
  display.setCursor(0, 11); display.println(l2);
  display.setCursor(0, 22); display.println(l3);
  display.setCursor(0, 33); display.println(l4);
  display.setCursor(0, 44); display.println(l5);
  display.setCursor(0, 55); display.println(l6);
  display.display();
}