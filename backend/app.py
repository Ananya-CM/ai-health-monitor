from flask import Flask, request, jsonify
import numpy as np
import tensorflow as tf
import json
import os
from datetime import datetime
import firebase_admin
from firebase_admin import credentials, db as firebase_db

app = Flask(__name__)

# ── Load all three models ──────────────────────────────────────────────────────
print("Loading models...")
BASE = os.path.dirname(os.path.abspath(__file__))

cnn_model   = tf.keras.models.load_model(os.path.join(BASE, 'models', 'cardiac_cnn.h5'))
autoencoder = tf.keras.models.load_model(os.path.join(BASE, 'models', 'lstm_autoencoder.keras'))
diabetes_lstm = tf.keras.models.load_model(os.path.join(BASE, 'models', 'diabetes_lstm.keras'))
AE_THRESHOLD  = float(np.load(os.path.join(BASE, 'models', 'ae_threshold.npy'))[0])

print(f"All models loaded. AE threshold: {AE_THRESHOLD:.6f}")

cred = credentials.Certificate(os.path.join(BASE, 'serviceAccountKey.json'))
firebase_admin.initialize_app(cred, {
    'databaseURL': 'https://ai-health-monitor-4927f-default-rtdb.asia-southeast1.firebasedatabase.app'
})
print("Firebase Admin connected")

# ── In-memory buffer for diabetes LSTM (needs 24 timesteps) ───────────────────
patient_buffers = {}  # patient_id -> list of feature vectors

# ── Alert classification ───────────────────────────────────────────────────────
def classify_alert(hr, spo2, temp, activity, glucose, cnn_prob, ae_error, diab_risk):

    alert_tier    = "NONE"
    alert_message = ""

    # RED — cardiac emergency
    if cnn_prob > 0.75 and ae_error > AE_THRESHOLD:
        if hr > 150 or hr < 40 or spo2 < 90:
            alert_tier    = "RED"
            alert_message = (f"CARDIAC ALERT: Arrhythmia detected. "
                             f"HR={hr:.0f} BPM, SpO2={spo2:.0f}%. "
                             f"Call ambulance immediately.")

    # RED — hypoglycemia (sweat glucose critically low)
    if glucose > 0 and glucose < 0.05:
        alert_tier    = "RED"
        alert_message = (f"HYPOGLYCEMIA ALERT: Sweat glucose critically low "
                         f"({glucose:.3f} mmol/L). Patient may lose consciousness.")

    # RED — tremor + tachycardia at rest (hypoglycemia signature)
    if activity > 0.8 and hr > 100 and glucose < 0.1:
        alert_tier    = "RED"
        alert_message = (f"HYPOGLYCEMIA ALERT: Tremor + elevated HR detected "
                         f"at rest. HR={hr:.0f}, Activity={activity:.2f}.")

    # AMBER — diabetes warning
    if alert_tier == "NONE":
        if diab_risk > 0.65 or (glucose > 0.80):
            alert_tier    = "AMBER"
            alert_message = (f"DIABETES WARNING: High glucose risk detected. "
                             f"Risk score={diab_risk:.2f}. "
                             f"Patient should check blood sugar.")

    # AMBER — cardiac pre-event
    if alert_tier == "NONE":
        if cnn_prob > 0.50 and hr > 100:
            alert_tier    = "AMBER"
            alert_message = (f"CARDIAC WARNING: Elevated heart rate with "
                             f"abnormal pattern. HR={hr:.0f}, "
                             f"CNN score={cnn_prob:.2f}.")

    # BLUE — advisory
    if alert_tier == "NONE":
        if diab_risk > 0.40:
            alert_tier    = "BLUE"
            alert_message = (f"DIABETES ADVISORY: Mild risk trend detected. "
                             f"Risk={diab_risk:.2f}. "
                             f"Schedule consultation within 48 hours.")

    return alert_tier, alert_message

# ── Main analysis endpoint ─────────────────────────────────────────────────────
@app.route('/analyse', methods=['POST'])
def analyse():
    try:
        data = request.get_json()
        patient_id = data.get('patient_id', 'default')

        # Extract sensor values
        hr       = float(data.get('hr', 0))
        spo2     = float(data.get('spo2', 0))
        hrv      = float(data.get('hrv_rmssd', 0))
        temp     = float(data.get('temp', 0))
        activity = float(data.get('activity', 0))
        glucose  = float(data.get('sweat_glucose', 0))

        # ── 1. CNN cardiac analysis ────────────────────────────────────────────
        # Use hr, spo2, hrv, temp, activity as a proxy 360-point window
        # In production this will be the actual PPG waveform from MAX30102
        cardiac_window = np.array([hr/200, spo2/100, hrv/100,
                                   temp/40, activity/3] * 72)[:360]
        cardiac_window = cardiac_window.reshape(1, 360, 1)
        cnn_prob = float(cnn_model.predict(cardiac_window, verbose=0)[0][0])

        # ── 2. LSTM Autoencoder anomaly verification ───────────────────────────
        ae_input = cardiac_window
        ae_recon = autoencoder.predict(ae_input, verbose=0)
        ae_error = float(np.mean(np.power(ae_input - ae_recon, 2)))

        # ── 3. Diabetes LSTM ───────────────────────────────────────────────────
        feature_vec = np.array([hr/200, temp/40, activity/3,
                                hrv/100, glucose])
        if patient_id not in patient_buffers:
            patient_buffers[patient_id] = []
        patient_buffers[patient_id].append(feature_vec)

        # Keep last 24 timesteps
        if len(patient_buffers[patient_id]) > 24:
            patient_buffers[patient_id].pop(0)

        if len(patient_buffers[patient_id]) == 24:
            lstm_input = np.array(patient_buffers[patient_id]).reshape(1, 24, 5)
            diab_risk  = float(diabetes_lstm.predict(lstm_input, verbose=0)[0][0])
        else:
            diab_risk = 0.0  # not enough data yet

        # ── 4. Alert classification ────────────────────────────────────────────
        alert_tier, alert_message = classify_alert(
            hr, spo2, temp, activity, glucose,
            cnn_prob, ae_error, diab_risk
        )

        # ── 5. Build response ──────────────────────────────────────────────────
        response = {
            "patient_id":    patient_id,
            "timestamp":     datetime.now().isoformat(),
            "vitals": {
                "hr": hr, "spo2": spo2, "hrv": hrv,
                "temp": temp, "activity": activity,
                "glucose": glucose
            },
            "ai_scores": {
                "cnn_cardiac_prob": round(cnn_prob, 4),
                "ae_reconstruction_error": round(ae_error, 6),
                "ae_threshold": round(AE_THRESHOLD, 6),
                "diabetes_risk": round(diab_risk, 4)
            },
            "alert": {
                "tier":    alert_tier,
                "message": alert_message
            },
            "buffer_size": len(patient_buffers[patient_id])
        }

        print(f"[{datetime.now().strftime('%H:%M:%S')}] "
              f"Patient {patient_id} | HR={hr} SpO2={spo2} "
              f"CNN={cnn_prob:.3f} Risk={diab_risk:.3f} "
              f"Alert={alert_tier}")

        # Write to Firebase so Flutter app updates in real time
        try:
            ref = firebase_db.reference(f'patient001/vitals')
            ref.set({
                'hr':            hr,
                'spo2':          spo2,
                'hrv_rmssd':     hrv,
                'temp':          temp,
                'activity':      activity,
                'sweat_glucose': glucose,
                'alert_tier':    alert_tier,
                'alert_message': alert_message,
                'cnn_prob':      round(cnn_prob, 4),
                'diabetes_risk': round(diab_risk, 4),
                'timestamp':     datetime.now().isoformat()
            })
        except Exception as e:
            print(f"Firebase write error: {e}")

        return jsonify(response), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ── Health check endpoint ──────────────────────────────────────────────────────
@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        "status": "running",
        "models": ["cardiac_cnn", "lstm_autoencoder", "diabetes_lstm"],
        "ae_threshold": AE_THRESHOLD,
        "timestamp": datetime.now().isoformat()
    }), 200

# ── Test endpoint — simulate all alert tiers ───────────────────────────────────
@app.route('/test/<tier>', methods=['GET'])
def test_alert(tier):
    test_data = {
        "RED":   {"hr":155,"spo2":88,"hrv_rmssd":8,"temp":37.2,
                  "activity":0.1,"sweat_glucose":0.03,"patient_id":"test_red"},
        "AMBER": {"hr":110,"spo2":96,"hrv_rmssd":20,"temp":37.8,
                  "activity":0.2,"sweat_glucose":0.85,"patient_id":"test_amber"},
        "BLUE":  {"hr":95, "spo2":96,"hrv_rmssd":15,"temp":37.5,
                  "activity":0.05,"sweat_glucose":0.55,"patient_id":"test_blue"}
    }
    if tier.upper() not in test_data:
        return jsonify({"error": "Use RED, AMBER, or BLUE"}), 400

    d = test_data[tier.upper()]
    pid = d["patient_id"]

    # Pre-fill buffer for BLUE with borderline diabetic values
    if tier.upper() == "BLUE":
        patient_buffers[pid] = []
        for _ in range(23):
            patient_buffers[pid].append(
                np.array([d["hr"]/200, d["temp"]/40,
                          d["activity"]/3, d["hrv_rmssd"]/100,
                          d["sweat_glucose"]])
            )

    with app.test_request_context(
        '/analyse', method='POST',
        content_type='application/json',
        data=json.dumps(d)
    ):
        return analyse()
    
if __name__ == '__main__':
    print("Starting Flask backend on port 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False)