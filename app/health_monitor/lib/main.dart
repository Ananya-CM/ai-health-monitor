import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_config.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey:            FirebaseConfig.apiKey,
      appId:             FirebaseConfig.appId,
      messagingSenderId: FirebaseConfig.messagingSenderId,
      projectId:         FirebaseConfig.projectId,
      databaseURL:       FirebaseConfig.databaseURL,
    ),
  );
  runApp(const HealthMonitorApp());
}

class HealthMonitorApp extends StatelessWidget {
  const HealthMonitorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Health Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF002060)),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double hr = 0, spo2 = 0, hrv = 0, temp = 0, glucose = 0, diabRisk = 0;
  String alertTier = "NONE", alertMessage = "";
  String lastUpdate = "Waiting for data...";
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _listenToFirebase();
  }

  void _listenToFirebase() {
    final ref = FirebaseDatabase.instance.ref('patient001/vitals');
    _sub = ref.onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      setState(() {
        hr       = double.tryParse(data['hr'].toString())             ?? 0;
        spo2     = double.tryParse(data['spo2'].toString())           ?? 0;
        hrv      = double.tryParse(data['hrv_rmssd'].toString())      ?? 0;
        temp     = double.tryParse(data['temp'].toString())           ?? 0;
        glucose  = double.tryParse(data['sweat_glucose'].toString())  ?? 0;
        diabRisk = double.tryParse(data['diabetes_risk'].toString())  ?? 0;
        alertTier    = data['alert_tier']?.toString()    ?? "NONE";
        alertMessage = data['alert_message']?.toString() ?? "";
        lastUpdate   = data['timestamp']?.toString().substring(11, 19) ?? "";
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Color get alertColor => alertTier == "RED"   ? const Color(0xFFE53935)
                        : alertTier == "AMBER" ? const Color(0xFFE65100)
                        : alertTier == "BLUE"  ? const Color(0xFF1565C0)
                        : Colors.transparent;

  Color get alertBg => alertTier == "RED"   ? const Color(0xFFFFEBEE)
                     : alertTier == "AMBER" ? const Color(0xFFFFF3E0)
                     : alertTier == "BLUE"  ? const Color(0xFFE3F2FD)
                     : Colors.transparent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Column(
        children: [
          // ── TOP BAR ────────────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF002060), Color(0xFF1565C0)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.monitor_heart, color: Colors.white, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'AI Health Monitor — Doctor Dashboard',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7, height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF69F0AE),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        lastUpdate.isEmpty ? 'Connecting...' : 'Live $lastUpdate',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── ALERT BANNER ───────────────────────────────────────────────────
          if (alertTier != "NONE")
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: alertBg,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: alertColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$alertTier ALERT',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      alertMessage,
                      style: TextStyle(
                        color: alertColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(Icons.warning_amber_rounded, color: alertColor, size: 20),
                ],
              ),
            ),

          // ── VITALS GRID ────────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  // Row 1
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _vitalCard(
                          'Heart Rate', '${hr.toStringAsFixed(0)} BPM',
                          Icons.favorite_rounded, const Color(0xFFE53935),
                          const Color(0xFFFFEBEE),
                          _hrStatus(),
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: _vitalCard(
                          'SpO\u2082', '${spo2.toStringAsFixed(0)} %',
                          Icons.air_rounded, const Color(0xFF1565C0),
                          const Color(0xFFE3F2FD),
                          spo2 < 95 ? 'Low — check patient' : 'Normal',
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: _vitalCard(
                          'HRV (RMSSD)', '${hrv.toStringAsFixed(0)} ms',
                          Icons.timeline_rounded, const Color(0xFF00695C),
                          const Color(0xFFE0F2F1),
                          hrv < 20 ? 'Low — monitor closely' : 'Normal',
                        )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Row 2
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _vitalCard(
                          'Temperature', '${temp.toStringAsFixed(1)} °C',
                          Icons.thermostat_rounded, const Color(0xFFE65100),
                          const Color(0xFFFFF3E0),
                          temp > 37.5 ? 'Elevated' : 'Normal',
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: _vitalCard(
                          'Sweat Glucose', '${glucose.toStringAsFixed(3)} mmol/L',
                          Icons.science_rounded, const Color(0xFF6A1B9A),
                          const Color(0xFFF3E5F5),
                          glucose < 0.05 ? '⚠ CRITICALLY LOW' :
                          glucose > 0.80 ? '⚠ HIGH' : 'Normal range',
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: _diabRiskCard()),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Status bar
                  _statusBar(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _hrStatus() {
    if (hr > 150) return '⚠ Tachycardia';
    if (hr < 40)  return '⚠ Bradycardia';
    if (hr > 100) return 'Elevated';
    return 'Normal';
  }

  Widget _vitalCard(String title, String value, IconData icon,
      Color color, Color bg, String status) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 26,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _diabRiskCard() {
    final riskPct = (diabRisk * 100).clamp(0, 100);
    final color = riskPct > 65 ? const Color(0xFFE53935)
                : riskPct > 40 ? const Color(0xFFE65100)
                : const Color(0xFF2E7D32);
    final bg    = riskPct > 65 ? const Color(0xFFFFEBEE)
                : riskPct > 40 ? const Color(0xFFFFF3E0)
                : const Color(0xFFE8F5E9);
    final label = riskPct > 65 ? 'HIGH RISK'
                : riskPct > 40 ? 'MODERATE'
                : 'LOW RISK';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.health_and_safety_rounded, color: color, size: 18),
              ),
              const SizedBox(width: 8),
              Text('Diabetes Risk',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
          const Spacer(),
          Text(
            '${riskPct.toStringAsFixed(1)} %',
            style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: riskPct / 100,
              backgroundColor: bg,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
            child: Text(label,
              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Container(width: 8, height: 8,
              decoration: const BoxDecoration(color: Color(0xFF69F0AE), shape: BoxShape.circle)),
            const SizedBox(width: 6),
            const Text('Live — updating every 5 seconds',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          Row(children: [
            const Icon(Icons.person_outline, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            const Text('Patient: patient001',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          Row(children: [
            const Icon(Icons.cloud_done_outlined, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            const Text('Firebase — Singapore',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
        ],
      ),
    );
  }
}