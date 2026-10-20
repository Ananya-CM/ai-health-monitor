from flask import Flask, request, jsonify
import numpy as np
import tensorflow as tf
import json
import os
import threading
import time
from datetime import datetime, timedelta
import firebase_admin
from firebase_admin import credentials, db as firebase_db
from firebase_admin import messaging

app = Flask(__name__)

# ── Load all three models ──────────────────────────────────────────────────────
print("Loading models...")
BASE = os.path.dirname(os.path.abspath(__file__))

cnn_model     = tf.keras.models.load_model(os.path.join(BASE, 'models', 'cardiac_cnn_ppg_final.h5'))
autoencoder   = tf.keras.models.load_model(os.path.join(BASE, 'models', 'lstm_autoencoder.keras'))
diabetes_lstm = tf.keras.models.load_model(os.path.join(BASE, 'models', 'diabetes_lstm.keras'))
AE_THRESHOLD  = float(np.load(os.path.join(BASE, 'models', 'ae_threshold.npy'))[0])

print(f"All models loaded. AE threshold: {AE_THRESHOLD:.6f}")

cred = credentials.Certificate(os.path.join(BASE, 'serviceAccountKey.json'))
firebase_admin.initialize_app(cred, {
    'databaseURL': 'https://ai-health-monitor-4927f-default-rtdb.asia-southeast1.firebasedatabase.app'
})
print("Firebase Admin connected")

# ── In-memory buffers ──────────────────────────────────────────────────────────
patient_buffers = {}  # patient_id -> list of feature vectors
last_alert_tier = {}  # patient_id -> last sent alert tier
hrv_history     = {}  # patient_id -> list of (timestamp, hrv) tuples
glucose_history = {}  # patient_id -> list of last 2 glucose readings
HRV_DECLINE_THRESHOLD = 0.30

# ── HRV trend analysis ─────────────────────────────────────────────────────────
def check_hrv_trend(patient_id, current_hrv):
    now = datetime.now()

    if patient_id not in hrv_history:
        hrv_history[patient_id] = []

    if current_hrv > 0:
        hrv_history[patient_id].append((now, current_hrv))

    cutoff = now - timedelta(days=7)
    hrv_history[patient_id] = [
        (t, v) for t, v in hrv_history[patient_id] if t > cutoff
    ]

    readings = hrv_history[patient_id]

    if len(readings) < 6:
        return False, 0.0

    oldest_time = readings[0][0]
    newest_time = readings[-1][0]
    span_hours  = (newest_time - oldest_time).total_seconds() / 3600

    if span_hours < 0.01:
        return False, 0.0

    quarter    = max(1, len(readings) // 4)
    early_hrv  = np.mean([v for _, v in readings[:quarter]])
    recent_hrv = np.mean([v for _, v in readings[-quarter:]])

    if early_hrv < 5.0:
        return False, 0.0

    decline_pct = (early_hrv - recent_hrv) / early_hrv

    print(f"  HRV trend: early={early_hrv:.1f}ms, recent={recent_hrv:.1f}ms, "
          f"decline={decline_pct*100:.1f}%, span={span_hours:.1f}hrs")

    if decline_pct >= HRV_DECLINE_THRESHOLD:
        return True, decline_pct

    return False, decline_pct

def is_hypo_confirmed(patient_id, glucose):
    if patient_id not in glucose_history:
        glucose_history[patient_id] = []
    glucose_history[patient_id].append(glucose)
    if len(glucose_history[patient_id]) > 2:
        glucose_history[patient_id].pop(0)
    return (len(glucose_history[patient_id]) == 2 and
            all(0 < g < 0.05 for g in glucose_history[patient_id]))

# ── Alert classification ───────────────────────────────────────────────────────
def classify_alert(hr, spo2, temp, activity, glucose, cnn_prob, ae_error, diab_risk, hypo_confirmed):

    alert_tier    = "NONE"
    alert_message = ""

    # RED — SpO2 hypoxia (immediate, no AI needed)
    if 0 < spo2 <= 100 and spo2 < 90:
        alert_tier    = "RED"
        alert_message = (f"HYPOXIA ALERT: Blood oxygen critically low at "
                         f"{spo2:.0f}%. Immediate oxygen support required.")
        return alert_tier, alert_message

    # RED — cardiac emergency (double confirmation)
    if cnn_prob > 0.75 and ae_error > AE_THRESHOLD:
        if hr > 150 or hr < 40 or spo2 < 94:
            alert_tier    = "RED"
            alert_message = (f"CARDIAC ALERT: Arrhythmia detected. "
                             f"HR={hr:.0f} BPM, SpO2={spo2:.0f}%. "
                             f"Call ambulance immediately.")

    # RED — hypoglycemia (confirmed over 2 consecutive readings)
    if hypo_confirmed:
        alert_tier    = "RED"
        alert_message = (f"HYPOGLYCEMIA ALERT: Sweat glucose critically low "
                         f"({glucose:.3f} mmol/L). Patient may lose consciousness.")

    # RED — tremor + tachycardia
    if activity > 0.8 and hr > 100 and glucose < 0.1:
        alert_tier    = "RED"
        alert_message = (f"HYPOGLYCEMIA ALERT: Tremor + elevated HR detected "
                         f"at rest. HR={hr:.0f}, Activity={activity:.2f}.")

    # AMBER — diabetes warning
    if alert_tier == "NONE":
        if diab_risk > 0.65 or glucose > 0.80:
            alert_tier = "AMBER"
            if diab_risk > 0.65:
                alert_message = (f"DIABETES WARNING: High diabetes risk detected. "
                                f"Risk score={diab_risk:.2f}. "
                                f"Patient should check blood sugar.")
            else:
                alert_message = (f"DIABETES WARNING: Elevated glucose level detected. "
                                f"Glucose={glucose:.2f} mmol/L. "
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

# ── Run AI models on sensor data ───────────────────────────────────────────────
def run_ai(patient_id, hr, spo2, hrv, temp, activity, glucose):
    # CNN cardiac window
    cardiac_window = np.array([hr/200, spo2/100, hrv/100,
                               temp/40, activity/3] * 72)[:360]
    cardiac_window = cardiac_window.reshape(1, 360, 1)

    cnn_prob = float(cnn_model.predict(cardiac_window, verbose=0)[0][0])

    ae_recon = autoencoder.predict(cardiac_window, verbose=0)
    ae_error = float(np.mean(np.power(cardiac_window - ae_recon, 2)))

    # Diabetes LSTM
    feature_vec = np.array([hr/200, temp/40, activity/3, hrv/100, glucose])
    if patient_id not in patient_buffers:
        patient_buffers[patient_id] = []
    patient_buffers[patient_id].append(feature_vec)
    if len(patient_buffers[patient_id]) > 24:
        patient_buffers[patient_id].pop(0)

    diab_risk = 0.0
    if len(patient_buffers[patient_id]) == 24:
        lstm_input = np.array(patient_buffers[patient_id]).reshape(1, 24, 5)
        diab_risk  = float(diabetes_lstm.predict(lstm_input, verbose=0)[0][0])

    # HRV trend + alert classification
    hypo_confirmed = is_hypo_confirmed(patient_id, glucose)
    hrv_declining, decline_pct = check_hrv_trend(patient_id, hrv)
    alert_tier, alert_message  = classify_alert(
        hr, spo2, temp, activity, glucose, cnn_prob, ae_error, diab_risk, hypo_confirmed
    )

    if alert_tier == "NONE" and hrv_declining:
        alert_tier    = "BLUE"
        alert_message = (f"DIABETES RISK RISING: HRV declining "
                         f"{decline_pct*100:.1f}% over monitoring period. "
                         f"Schedule consultation within 48 hours.")

    return cnn_prob, ae_error, diab_risk, alert_tier, alert_message

# ── Firebase listener — reads ESP32 data and runs AI ──────────────────────────
PATIENT_PREFIX = 'patient'

def discover_patient_ids():
    """Return every top-level Firebase node that looks like a patient record."""
    keys = firebase_db.reference('/').get(shallow=True) or {}
    return sorted(k for k in keys if k.startswith(PATIENT_PREFIX))

def process_patient(patient_id):
    """Run the AI pipeline on one patient's latest vitals and write results back."""
    vitals_ref = firebase_db.reference(f'{patient_id}/vitals')
    data = vitals_ref.get()
    if not data or not isinstance(data, dict):
        return

    hr       = float(data.get('hr', 0))
    spo2     = float(data.get('spo2', 0))
    hrv      = float(data.get('hrv_rmssd', 0))
    temp     = float(data.get('temp', 0))
    activity = float(data.get('activity', 0))
    glucose  = float(data.get('sweat_glucose', 0))

    if hr <= 0:
        return

    cnn_prob, ae_error, diab_risk, alert_tier, alert_message = \
        run_ai(patient_id, hr, spo2, hrv, temp, activity, glucose)

    vitals_ref.update({
        'alert_tier':    alert_tier,
        'alert_message': alert_message,
        'cnn_prob':      round(cnn_prob, 4),
        'diabetes_risk': round(diab_risk, 4),
        'timestamp':     datetime.now().isoformat(),
    })

    if alert_tier in ("RED", "AMBER") and last_alert_tier.get(patient_id) != alert_tier:
        send_fcm_alert(alert_tier, alert_message, patient_id)
    last_alert_tier[patient_id] = alert_tier

    print(f"[{patient_id}] HR={hr} SpO2={spo2} "
          f"Glu={glucose:.3f} CNN={cnn_prob:.3f} "
          f"AE={ae_error:.4f} Risk={diab_risk:.3f} "
          f"Alert={alert_tier}")

def firebase_listener():
    print("Firebase listener started — watching all patient*/vitals nodes...")

    while True:
        try:
            patient_ids = discover_patient_ids()
        except Exception as e:
            print(f"Listener error (patient discovery): {e}")
            patient_ids = []

        for patient_id in patient_ids:
            try:
                process_patient(patient_id)
            except Exception as e:
                # One failing patient must not stop monitoring of the others.
                print(f"Listener error ({patient_id}): {e}")

        time.sleep(5)

def send_fcm_alert(alert_tier, alert_message, patient_id='patient001'):
    """Send the alert to every signed-in doctor's device.

    Each doctor's app registers its own token at doctor_tokens/<uid>.
    """
    tokens = firebase_db.reference('doctor_tokens').get() or {}
    if not tokens:
        print("[FCM] No doctor device tokens registered yet")
        return
    for doctor_uid, token in tokens.items():
        if not token:
            continue
        msg = messaging.Message(
            notification=messaging.Notification(
                title=f"{alert_tier} ALERT — {patient_id}",
                body=alert_message
            ),
            token=token
        )
        try:
            response = messaging.send(msg)
            print(f"[FCM] Sent to {doctor_uid[:6]}...: {response}")
        except messaging.UnregisteredError:
            # App was uninstalled or the token expired: stop sending to it.
            firebase_db.reference(f'doctor_tokens/{doctor_uid}').delete()
            print(f"[FCM] Removed stale token for {doctor_uid[:6]}...")
        except Exception as e:
            print(f"[FCM] Failed for {doctor_uid[:6]}...: {e}")

# ── Main analysis endpoint ─────────────────────────────────────────────────────
@app.route('/analyse', methods=['POST'])
def analyse():
    try:
        data       = request.get_json()
        patient_id = data.get('patient_id', 'default')

        hr       = float(data.get('hr', 0))
        spo2     = float(data.get('spo2', 0))
        hrv      = float(data.get('hrv_rmssd', 0))
        temp     = float(data.get('temp', 0))
        activity = float(data.get('activity', 0))
        glucose  = float(data.get('sweat_glucose', 0))

        cnn_prob, ae_error, diab_risk, alert_tier, alert_message = \
            run_ai(patient_id, hr, spo2, hrv, temp, activity, glucose)

        response = {
            "patient_id":  patient_id,
            "timestamp":   datetime.now().isoformat(),
            "vitals": {
                "hr": hr, "spo2": spo2, "hrv": hrv,
                "temp": temp, "activity": activity, "glucose": glucose
            },
            "ai_scores": {
                "cnn_cardiac_prob":       round(cnn_prob, 4),
                "ae_reconstruction_error": round(ae_error, 6),
                "ae_threshold":           round(AE_THRESHOLD, 6),
                "diabetes_risk":          round(diab_risk, 4)
            },
            "alert": {
                "tier":    alert_tier,
                "message": alert_message
            },
            "buffer_size": len(patient_buffers.get(patient_id, []))
        }

        print(f"[{datetime.now().strftime('%H:%M:%S')}] "
              f"Patient {patient_id} | HR={hr} SpO2={spo2} "
              f"CNN={cnn_prob:.3f} Risk={diab_risk:.3f} "
              f"Alert={alert_tier}")

        # Write to Firebase. Real patient IDs map to their own node; ad-hoc/test
        # IDs fall back to the demo patient so the dashboard still shows them.
        FIREBASE_TARGET = patient_id if patient_id.startswith(PATIENT_PREFIX) else 'patient001'
        try:
            firebase_db.reference(f'{FIREBASE_TARGET}/vitals').set({
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
            if alert_tier in ("RED", "AMBER"):
                send_fcm_alert(alert_tier, alert_message, FIREBASE_TARGET)
        except Exception as e:
            print(f"Firebase write error: {e}")

        return jsonify(response), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500

# ── Health check ───────────────────────────────────────────────────────────────
@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        "status":       "running",
        "models":       ["cardiac_cnn", "lstm_autoencoder", "diabetes_lstm"],
        "ae_threshold": AE_THRESHOLD,
        "timestamp":    datetime.now().isoformat()
    }), 200

# ── Test endpoint ──────────────────────────────────────────────────────────────
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

    d   = test_data[tier.upper()]
    pid = d["patient_id"]

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

# ── Start ──────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    # Start Firebase listener thread — processes real ESP32 data
    t = threading.Thread(target=firebase_listener, daemon=True)
    t.start()
    print("Starting Flask backend on port 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False)