import requests
import time
import random

URL = "http://localhost:5000/analyse"

print("Simulating ESP32 sensor data every 5 seconds...")
print("Press Ctrl+C to stop\n")

reading = 0
while True:
    reading += 1
    payload = {
        "patient_id":    "patient001",
        "hr":            round(72 + random.gauss(0, 5), 1),
        "spo2":          round(98 + random.gauss(0, 0.5), 1),
        "hrv_rmssd":     round(42 + random.gauss(0, 3), 1),
        "temp":          round(36.7 + random.gauss(0, 0.1), 1),
        "activity":      round(random.uniform(0.1, 0.4), 2),
        "sweat_glucose": round(0.12 + random.gauss(0, 0.02), 3)
    }
    try:
        r    = requests.post(URL, json=payload, timeout=10)
        data = r.json()
        print(f"Reading {reading:03d} | HR={payload['hr']} "
              f"SpO2={payload['spo2']} | "
              f"Risk={data['ai_scores']['diabetes_risk']:.3f} "
              f"Buffer={data['buffer_size']}/24 | "
              f"Alert={data['alert']['tier']}")
    except Exception as e:
        print(f"Error: {e}")
    time.sleep(5)