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
  Color alertColor = Colors.green;
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
        hr       = double.tryParse(data['hr'].toString())            ?? 0;
        spo2     = double.tryParse(data['spo2'].toString())          ?? 0;
        hrv      = double.tryParse(data['hrv_rmssd'].toString())     ?? 0;
        temp     = double.tryParse(data['temp'].toString())          ?? 0;
        glucose  = double.tryParse(data['sweat_glucose'].toString()) ?? 0;
        diabRisk = double.tryParse(data['diabetes_risk'].toString()) ?? 0;
        alertTier    = data['alert_tier']?.toString()    ?? "NONE";
        alertMessage = data['alert_message']?.toString() ?? "";
        alertColor   = alertTier == "RED"   ? Colors.red
                     : alertTier == "AMBER" ? Colors.orange
                     : alertTier == "BLUE"  ? Colors.blue
                     : Colors.green;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF002060),
        title: const Text('AI Health Monitor — Doctor Dashboard',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (alertTier != "NONE")
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: alertColor.withOpacity(0.15),
                  border: Border.all(color: alertColor, width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.warning_amber_rounded,
                          color: alertColor, size: 22),
                      const SizedBox(width: 8),
                      Text('$alertTier ALERT',
                          style: TextStyle(color: alertColor,
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ]),
                    const SizedBox(height: 6),
                    Text(alertMessage,
                        style: TextStyle(color: alertColor, fontSize: 13)),
                  ],
                ),
              ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: [
                _vitalCard("Heart Rate",    "${hr.toStringAsFixed(0)} BPM",
                    Icons.favorite, Colors.red),
                _vitalCard("SpO\u2082",     "${spo2.toStringAsFixed(0)} %",
                    Icons.air, Colors.blue),
                _vitalCard("HRV (RMSSD)",   "${hrv.toStringAsFixed(0)} ms",
                    Icons.timeline, Colors.teal),
                _vitalCard("Temperature",   "${temp.toStringAsFixed(1)} \u00b0C",
                    Icons.thermostat, Colors.orange),
                _vitalCard("Sweat Glucose", "${glucose.toStringAsFixed(3)} mmol/L",
                    Icons.science, Colors.purple),
                _vitalCard("Diabetes Risk", "${(diabRisk*100).toStringAsFixed(1)} %",
                    Icons.health_and_safety, Colors.indigo),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.circle, color: Colors.green, size: 10),
                  const SizedBox(width: 8),
                  Text('Live — updating every 5 seconds',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vitalCard(String title, String value,
      IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(
            color: Colors.black12, blurRadius: 4,
            offset: const Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(title,
                style: TextStyle(
                    color: Colors.grey.shade600, fontSize: 11),
                overflow: TextOverflow.ellipsis)),
          ]),
          Text(value, style: TextStyle(
              color: color, fontSize: 22,
              fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}