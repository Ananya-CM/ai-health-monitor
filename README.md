# 🏥 AI-Powered Dual Wearable Health Monitoring System

A real-time IoT + AI health monitoring system that uses wearable sensors to track vital signs, runs three AI models on a cloud backend, and displays intelligent alerts on a Flutter dashboard — all connected via Firebase.

---

## 📸 Screenshots

| RED Alert (Hypoglycemia) | AMBER Alert (Diabetes Risk) | Normal Vitals |
|:---:|:---:|:---:|
| Glucose: 0.008 mmol/L | Glucose: 0.81 mmol/L | All vitals normal |

---

## 🏗️ System Architecture

```
┌─────────────┐        ┌──────────────┐        ┌─────────────────────┐
│   ESP32     │──WiFi──▶   Firebase   │◀──────▶│   Flask AI Backend  │
│  (Sensors)  │        │  Realtime DB │        │  (3 AI Models)      │
└─────────────┘        └──────────────┘        └─────────────────────┘
                               │
                               ▼
                       ┌──────────────┐
                       │   Flutter    │
                       │  Dashboard   │
                       └──────────────┘
```

**Data Flow:**
1. ESP32 reads sensors every 5 seconds → pushes to Firebase (`<patient_id>/vitals`, e.g. `patient001/vitals`)
2. Flask listener scans every `patient*` node → runs all 3 AI models for each patient
3. Flask writes `alert_tier`, `alert_message`, risk scores and a `timestamp` back to Firebase
4. For RED / AMBER alerts Flask sends a push notification (FCM) to the doctor's phone
5. Flutter dashboard reads Firebase in real time → shows vitals, alerts and a live trend graph

---

## ✨ Features

- Live vitals dashboard: heart rate, SpO₂, HRV (RMSSD), temperature, sweat glucose, diabetes risk
- **Live trend graph** (fl_chart): last 60 readings for any vital, with a chip selector and touch tooltips
- **Multi-patient backend**: the listener auto-discovers every `patient*` node in Firebase; one failing patient never blocks the others
- Four-tier alerts (RED / AMBER / BLUE / NONE) with FCM push notifications
- **Offline buffering on the ESP32**: if Wi-Fi or Firebase is down, up to 120 readings (~10 min) are kept in RAM, Wi-Fi is retried every 10 s, and the buffered readings are uploaded to `<patient_id>/backfill` when the connection returns (timestamps come from NTP)

---

## 🔧 Hardware Components

| Component | Function | Interface |
|-----------|----------|-----------|
| ESP32-WROOM-32 | Main microcontroller | — |
| MAX30102 | Heart rate + SpO₂ | I2C (GPIO 21/22, addr 0x57) |
| DS18B20 | Body temperature | 1-Wire (GPIO 4, 4.7kΩ pull-up) |
| MPU6050 | Activity / tremor detection | I2C (GPIO 21/22, addr 0x68) |
| Potentiometer | Sweat glucose simulation | ADC (GPIO 34) |
| SSD1306 OLED | Local display (128×64) | I2C |

---

## 🤖 AI Models

### 1. Cardiac CNN (`cardiac_cnn_ppg_final.h5`)
- Three-stage transfer learning: ECG → PPG
- ECG accuracy: **98.84%** | PPG fine-tuned: **68.19%**
- Detects cardiac anomalies from PPG waveform

### 2. LSTM Autoencoder (`lstm_autoencoder.keras`)
- Reconstruction threshold: **0.020282**
- Detects unusual vital sign patterns (anomaly detection)

### 3. Diabetes LSTM (`diabetes_lstm.keras`)
- AUC: **98.97%** | Accuracy: **94.68%**
- Predicts diabetes risk from glucose, HR, HRV, activity

---

## 🚨 Alert Classification

| Tier | Condition | Meaning |
|------|-----------|---------|
| 🔴 RED | SpO₂ < 90% | Hypoxia — immediate danger |
| 🔴 RED | CNN > 0.75 AND AE > 0.020282 AND (HR > 150 or HR < 40 or SpO₂ < 94) | Cardiac event |
| 🔴 RED | Glucose < 0.05 mmol/L | Hypoglycemia |
| 🔴 RED | Activity > 0.8 AND HR > 100 AND Glucose < 0.1 | Tremor episode |
| 🟡 AMBER | Diabetes risk > 0.65 OR Glucose > 0.80 mmol/L | High diabetes risk |
| 🟡 AMBER | CNN > 0.50 AND HR > 100 | Cardiac pre-event |
| 🔵 BLUE | Diabetes risk > 0.40 | Advisory |
| 🔵 BLUE | HRV declining > 30% over monitoring period | HRV warning |

---

## 🛠️ Setup & Installation

### Prerequisites
- Python 3.8+
- Flutter 3.x
- Arduino IDE (for ESP32 firmware)
- Firebase project (Realtime Database)

---

### 1. Firebase Setup

1. Create a project at [console.firebase.google.com](https://console.firebase.google.com)
2. Enable **Realtime Database** (choose Asia-Southeast1 region)
3. Set database rules to allow read/write (for development):
```json
{
  "rules": {
    ".read": true,
    ".write": true
  }
}
```
4. Download `google-services.json` and place it in `app/health_monitor/android/app/`

---

### 2. ESP32 Firmware

1. Open `firmware/esp32_health_monitor/esp32_health_monitor.ino` in Arduino IDE
   (create `secrets.h` next to it with `WIFI_SSID`, `WIFI_PASSWORD`, `FIREBASE_HOST`, `FIREBASE_AUTH` — it is not committed)
2. Install the following libraries:
   - `MAX30105` (SparkFun)
   - `DallasTemperature` + `OneWire`
   - `MPU6050`
   - `Adafruit_SSD1306`
   - `Firebase ESP Client` (Mobizt)
   - `Adafruit_GFX`
3. Put your WiFi credentials and Firebase URL / secret in `secrets.h`:
```cpp
#define WIFI_SSID      "YourWiFiName"
#define WIFI_PASSWORD  "YourPassword"
#define FIREBASE_HOST  "https://your-project.firebasedatabase.app"
#define FIREBASE_AUTH  "your-database-secret"
```
4. Upload to ESP32 (115200 baud)

---

### 3. Flask AI Backend

```bash
# Clone the repository
git clone https://github.com/Ananya-CM/ai-health-monitor.git
cd ai-health-monitor/backend

# Install dependencies
pip install -r requirements.txt

# Firebase Admin credentials: download a service-account key from
# Firebase console → Project settings → Service accounts and save it as
# backend/serviceAccountKey.json (not committed). Set your database URL in app.py.

# Place the three trained models in backend/models/ (not committed):
#   cardiac_cnn_ppg_final.h5, lstm_autoencoder.keras, diabetes_lstm.keras, ae_threshold.npy

# Run the backend
python app.py
```

On Windows, `start_backend.bat` launches the backend in one click (edit the folder path inside it first).

Other endpoints: `POST /analyse` (run the models on one reading), `GET /health`, `GET /test/RED|AMBER|BLUE` (demo alerts).

The Flask server runs on `http://0.0.0.0:5000`. A background thread checks every `patient*` node in Firebase every 5 seconds and processes each patient's vitals through all 3 AI models. To add a patient, write vitals to `patientXXX/vitals` — no backend change is needed (add the patient to `kPatients` in the Flutter app to show them in the list).

**Expected terminal output:**
```
[patient001] HR=75 SpO2=99 Glu=0.320 CNN=0.123 AE=0.011 Risk=0.31 Alert=NONE
[patient001] HR=80 SpO2=97 Glu=0.008 CNN=0.145 AE=0.009 Risk=0.02 Alert=RED
```

---

### 4. Flutter Dashboard

```bash
cd app/health_monitor

# Install dependencies
flutter pub get

# Run in Chrome (web)
flutter run -d chrome

# Build Android APK
flutter build apk --release
```

Make sure `google-services.json` is in `android/app/` before building, and replace the Firebase web config in `lib/firebase_config.dart` with your own project's values.

**Android notifications:** some phones delay or block notifications for battery saving. On the doctor's phone, set the app's battery usage to *Unrestricted* (Settings → Apps → AI Health Monitor → Battery) so alerts arrive when the phone is locked.

---

## 📁 Project Structure

```
ai-health-monitor/
├── backend/
│   ├── app.py                        # Flask server + Firebase listener
│   └── models/
│       ├── cardiac_cnn_ppg_final.h5
│       ├── lstm_autoencoder.keras
│       └── diabetes_lstm.keras
├── firmware/
│   └── esp32_health_monitor/
│       └── esp32_health_monitor.ino  # Arduino sketch for ESP32 (+ secrets.h, not committed)
├── app/
│   └── health_monitor/               # Flutter project
│       ├── lib/
│       │   └── main.dart             # Dashboard UI + Firebase
│       └── android/
│           └── app/
│               └── google-services.json
└── notebooks/
    ├── cardiac_cnn_training.ipynb
    ├── lstm_autoencoder_training.ipynb
    └── diabetes_lstm_training.ipynb
```

---

## 📊 Model Training

All models were trained in Google Colab. Notebooks are in the `notebooks/` folder.

**Dataset sources:**
- Cardiac CNN: PhysioNet ECG database + custom PPG recordings
- LSTM Autoencoder: Synthetic vital sign sequences
- Diabetes LSTM: PIMA Indians Diabetes Dataset + glucose augmentation

**Trained models are saved to Google Drive:**
```
/content/drive/MyDrive/ai-health-monitor/models/
```

---

## ⚠️ Known Limitations

| Claimed Feature | Reality | Notes |
|----------------|---------|-------|
| CNN on PPG | ECG-to-PPG transfer gap: 98.84% → 68.19% | Disclosed in paper |
| SpO₂ accuracy | Breadboard noise (±14%) | Disclosed |
| True RMSSD HRV | Estimated from HR (60000/HR) | Future firmware work |
| Sweat glucose biosensor | Potentiometer simulation | Research prototype |
| Firebase India region | Singapore region (closest available) | Future work |
| Offline buffer | Kept in RAM only; lost if the ESP32 reboots, oldest data dropped after ~10 min | Future work: flash storage |
| Notifications | One doctor device token (`doctor_device/fcm_token`) for all patients | Future work: per-doctor accounts |
| Models / notebooks | Trained models are not committed to the repo | Add to `backend/models/` locally |

> This is a **research prototype** demonstrating AI-assisted health monitoring. It is not a certified medical device.

---

## 🔬 Key Contributions

1. Three-model AI pipeline (Cardiac CNN + LSTM Autoencoder + Diabetes LSTM) running on commodity hardware
2. ECG-to-PPG transfer learning with quantified domain gap analysis
3. HRV trend analysis with dynamic threshold alerts
4. End-to-end pipeline: IoT sensors → Firebase → AI inference → Flutter dashboard
5. Four-tier alert classification (RED / AMBER / BLUE / NONE) with clinical reasoning

---

## 📄 License

This project is developed for academic and research purposes.

---

## 🙏 Acknowledgements

We acknowledge the open-source communities behind TensorFlow, Flutter, Firebase, Arduino, and the PhysioNet database for making this research possible.
