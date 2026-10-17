import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_config.dart';
import 'dart:async';
import 'package:fl_chart/fl_chart.dart';

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
  // Push notifications are for the Android app. On Chrome (web) they need a
  // service-worker file, so skip them there; any FCM failure must never
  // stop the dashboard from loading.
  if (!kIsWeb) {
    try {
      await setupFCM();
    } catch (e) {
      debugPrint('FCM setup failed: $e');
    }
  }
  runApp(const HealthMonitorApp());
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await requestBatteryExemption();
  }
}

/// Android may delay background notifications to save battery. Ask the user
/// once per launch (until granted) to exempt this app so alerts arrive on time.
Future<void> requestBatteryExemption() async {
  try {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!status.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (e) {
    debugPrint('Battery optimisation request failed: $e');
  }
}

Future<void> setupFCM() async {
  await FirebaseMessaging.instance.requestPermission();

  String? token = await FirebaseMessaging.instance.getToken();
  if (token != null) {
    await FirebaseDatabase.instance
        .ref('doctor_device/fcm_token')
        .set(token);
  }

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    // optional: show banner/snackbar while app is open
  });
}

// ─── Patient model ────────────────────────────────────────────────────────────
class Patient {
  final String id;
  final String name;
  final int    age;
  final String condition;
  final String room;
  final bool   hasDevice;

  const Patient({
    required this.id,
    required this.name,
    required this.age,
    required this.condition,
    required this.room,
    this.hasDevice = false,
  });
}

const List<Patient> kPatients = [
  Patient(id: 'patient001', name: 'Arjun Sharma',  age: 58, condition: 'Cardiac monitoring',  room: 'Ward A · Bed 1', hasDevice: true),
  Patient(id: 'patient002', name: 'Meena Patel',   age: 45, condition: 'Diabetes management', room: 'Ward A · Bed 2'),
  Patient(id: 'patient003', name: 'Ravi Krishnan', age: 67, condition: 'Post-surgery care',   room: 'Ward B · Bed 1'),
  Patient(id: 'patient004', name: 'Sunita Reddy',  age: 52, condition: 'Hypertension',        room: 'Ward B · Bed 3'),
  Patient(id: 'patient005', name: 'Vikram Nair',   age: 39, condition: 'Respiratory care',    room: 'Ward C · Bed 2'),
];

// ─── App root ─────────────────────────────────────────────────────────────────
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
      home: const PatientListScreen(),
    );
  }
}

// ─── Top Bar widget ───────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final String title;
  final bool showBack;
  final Widget? trailing;
  const _TopBar({required this.title, this.showBack = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(showBack ? 4 : 20, 12, 20, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF002060), Color(0xFF1565C0)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          const Icon(Icons.monitor_heart, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ─── Patient List Screen ──────────────────────────────────────────────────────
class PatientListScreen extends StatelessWidget {
  const PatientListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Column(
        children: [
          const _TopBar(title: 'AI Health Monitor — Patients'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            color: Colors.white,
            child: const Text(
              'Select a patient to view their live vitals and AI alerts.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: kPatients.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final patient = kPatients[index];
                return _PatientCard(
                  patient: patient,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => patient.hasDevice
                          ? DashboardScreen(patient: patient)
                          : NoDeviceScreen(patient: patient),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Patient Card ─────────────────────────────────────────────────────────────
class _PatientCard extends StatelessWidget {
  final Patient patient;
  final VoidCallback onTap;
  const _PatientCard({required this.patient, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF002060).withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: patient.hasDevice
                    ? const Color(0xFFE3F2FD)
                    : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  patient.name.split(' ').map((w) => w[0]).take(2).join(),
                  style: TextStyle(
                    color: patient.hasDevice
                        ? const Color(0xFF1565C0)
                        : Colors.grey,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(patient.name,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E))),
                  const SizedBox(height: 3),
                  Text('Age ${patient.age}  ·  ${patient.condition}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Icon(Icons.location_on_outlined, size: 12, color: Colors.grey),
                    const SizedBox(width: 3),
                    Text(patient.room,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ]),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: patient.hasDevice
                        ? const Color(0xFFE8F5E9)
                        : const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: patient.hasDevice
                          ? const Color(0xFF2E7D32)
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(children: [
                    Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        color: patient.hasDevice
                            ? const Color(0xFF2E7D32)
                            : Colors.grey.shade400,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      patient.hasDevice ? 'Active' : 'No device',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: patient.hasDevice
                            ? const Color(0xFF2E7D32)
                            : Colors.grey.shade500,
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFF1565C0), size: 24),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── No Device Screen ─────────────────────────────────────────────────────────
class NoDeviceScreen extends StatelessWidget {
  final Patient patient;
  const NoDeviceScreen({super.key, required this.patient});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Column(
        children: [
          _TopBar(title: '${patient.name} — Dashboard', showBack: true),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.15),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.sensors_off_rounded,
                          size: 56, color: Color(0xFFB0BEC5)),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'No wearable device connected',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E)),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'This patient does not have an ESP32 wearable device assigned yet. '
                      'Attach a device to begin real-time monitoring.',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                          height: 1.5),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.grey.withOpacity(0.1),
                              blurRadius: 10,
                              offset: const Offset(0, 3)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Patient Details',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey)),
                          const SizedBox(height: 12),
                          _infoRow(Icons.person_outline, patient.name),
                          const SizedBox(height: 8),
                          _infoRow(Icons.cake_outlined, 'Age ${patient.age}'),
                          const SizedBox(height: 8),
                          _infoRow(Icons.medical_services_outlined, patient.condition),
                          const SizedBox(height: 8),
                          _infoRow(Icons.location_on_outlined, patient.room),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new, size: 14),
                      label: const Text('Back to patient list'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1565C0),
                        side: const BorderSide(color: Color(0xFF1565C0)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 16, color: const Color(0xFF1565C0)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A2E))),
      ),
    ]);
  }
}

// ─── Live trend graph configuration ──────────────────────────────────────────
class _TrendCfg {
  final Color color;
  final String unit;
  final int decimals;
  final double minY, maxY, minPad;
  const _TrendCfg(this.color, this.unit, this.decimals, this.minY, this.maxY,
      this.minPad);
}

const Map<String, _TrendCfg> _trendSeries = {
  'Heart Rate':  _TrendCfg(Color(0xFFE53935), 'BPM',    0, 40, 140, 5),
  'SpO\u2082':    _TrendCfg(Color(0xFF1565C0), '%',      0, 85, 100, 1),
  'HRV':         _TrendCfg(Color(0xFF00695C), 'ms',     0, 0, 100,  5),
  'Temperature': _TrendCfg(Color(0xFFE65100), '\u00b0C', 1, 35, 39,  0.3),
  'Glucose':     _TrendCfg(Color(0xFF6A1B9A), 'mmol/L', 3, 0, 1,    0.05),
};

// ─── Dashboard Screen ─────────────────────────────────────────────────────────
class DashboardScreen extends StatefulWidget {
  final Patient patient;
  const DashboardScreen({super.key, required this.patient});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double hr = 0, spo2 = 0, hrv = 0, temp = 0, glucose = 0, diabRisk = 0;
  String alertTier = 'NONE', alertMessage = '';
  String lastUpdate = '';
  bool connected = false;
  StreamSubscription? _sub;

  // Rolling history for the live trend graph (one point per 5 s reading).
  static const int _maxPoints = 60;
  final Map<String, List<double>> _history = {
    for (final k in _trendSeries.keys) k: <double>[],
  };
  String _selectedTrend = 'Heart Rate';
  String _lastTimestamp = '';

  @override
  void initState() {
    super.initState();
    _listenToFirebase();
  }

  void _listenToFirebase() {
    final ref = FirebaseDatabase.instance.ref('${widget.patient.id}/vitals');
    _sub = ref.onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      setState(() {
        connected    = true;
        hr           = double.tryParse(data['hr'].toString())            ?? 0;
        spo2         = double.tryParse(data['spo2'].toString())          ?? 0;
        hrv          = double.tryParse(data['hrv_rmssd'].toString())     ?? 0;
        temp         = double.tryParse(data['temp'].toString())          ?? 0;
        glucose      = double.tryParse(data['sweat_glucose'].toString()) ?? 0;
        diabRisk     = double.tryParse(data['diabetes_risk'].toString()) ?? 0;
        alertTier    = data['alert_tier']?.toString()    ?? 'NONE';
        alertMessage = data['alert_message']?.toString() ?? '';
        final ts     = data['timestamp']?.toString() ?? '';
        lastUpdate   = ts.length >= 19 ? ts.substring(11, 19) : ts;

        // Append only when a new reading arrives (avoid duplicate points).
        if (ts.isNotEmpty && ts != _lastTimestamp) {
          _lastTimestamp = ts;
          _pushPoint('Heart Rate', hr);
          _pushPoint('SpO\u2082', spo2);
          _pushPoint('HRV', hrv);
          _pushPoint('Temperature', temp);
          _pushPoint('Glucose', glucose);
        }
      });
    });
  }

  void _pushPoint(String key, double value) {
    final list = _history[key]!;
    list.add(value);
    if (list.length > _maxPoints) list.removeAt(0);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Color get alertColor => alertTier == 'RED'   ? const Color(0xFFE53935)
                        : alertTier == 'AMBER' ? const Color(0xFFE65100)
                        : alertTier == 'BLUE'  ? const Color(0xFF1565C0)
                        : Colors.transparent;

  Color get alertBg => alertTier == 'RED'   ? const Color(0xFFFFEBEE)
                     : alertTier == 'AMBER' ? const Color(0xFFFFF3E0)
                     : alertTier == 'BLUE'  ? const Color(0xFFE3F2FD)
                     : Colors.transparent;

  String _hrStatus() {
    if (hr > 150) return '\u26a0 Tachycardia';
    if (hr < 40)  return '\u26a0 Bradycardia';
    if (hr > 100) return 'Elevated';
    return 'Normal';
  }

  @override
  Widget build(BuildContext context) {
    // Live indicator widget for top bar
    final liveIndicator = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(children: [
        Container(
          width: 7, height: 7,
          decoration: BoxDecoration(
            color: connected ? const Color(0xFF69F0AE) : Colors.orange,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          connected
              ? (lastUpdate.isEmpty ? 'Live' : 'Live $lastUpdate')
              : 'Connecting...',
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ]),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: Column(
        children: [
          _TopBar(
            title: '${widget.patient.name}',
            showBack: true,
            trailing: liveIndicator,
          ),

          // Alert banner
          if (alertTier != 'NONE')
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: alertBg,
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: alertColor,
                      borderRadius: BorderRadius.circular(4)),
                  child: Text('$alertTier ALERT',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(alertMessage,
                      style: TextStyle(
                          color: alertColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                ),
                Icon(Icons.warning_amber_rounded, color: alertColor, size: 20),
              ]),
            ),

          // ── Vitals: single column scrollable list ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                _vitalCard('Heart Rate', '${hr.toStringAsFixed(0)} BPM',
                    Icons.favorite_rounded,
                    const Color(0xFFE53935), const Color(0xFFFFEBEE),
                    _hrStatus()),
                const SizedBox(height: 12),
                _vitalCard('SpO\u2082', '${spo2.toStringAsFixed(0)} %',
                    Icons.air_rounded,
                    const Color(0xFF1565C0), const Color(0xFFE3F2FD),
                    spo2 < 95 ? 'Low — check patient' : 'Normal'),
                const SizedBox(height: 12),
                _vitalCard('HRV (RMSSD)', '${hrv.toStringAsFixed(0)} ms',
                    Icons.timeline_rounded,
                    const Color(0xFF00695C), const Color(0xFFE0F2F1),
                    hrv < 20 ? 'Low — monitor closely' : 'Normal'),
                const SizedBox(height: 12),
                _vitalCard('Temperature', '${temp.toStringAsFixed(1)} \u00b0C',
                    Icons.thermostat_rounded,
                    const Color(0xFFE65100), const Color(0xFFFFF3E0),
                    temp > 37.5 ? 'Elevated' : 'Normal'),
                const SizedBox(height: 12),
                _vitalCard(
                    'Sweat Glucose',
                    '${glucose.toStringAsFixed(3)} mmol/L',
                    Icons.science_rounded,
                    const Color(0xFF6A1B9A), const Color(0xFFF3E5F5),
                    glucose < 0.05
                        ? '\u26a0 Critically Low'
                        : glucose > 0.80
                            ? '\u26a0 High'
                            : 'Normal range'),
                const SizedBox(height: 12),
                _diabRiskCard(),
                const SizedBox(height: 12),
                _trendCard(),
                const SizedBox(height: 12),
                _statusBar(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vitalCard(String title, String value, IconData icon,
      Color color, Color bg, String status) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: color.withOpacity(0.10),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          // Icon badge
          Container(
            padding: const EdgeInsets.all(10),
            decoration:
                BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          // Title + status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(20)),
                  child: Text(status,
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          // Value
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5)),
        ],
      ),
    );
  }

  Widget _trendCard() {
    final cfg = _trendSeries[_selectedTrend]!;
    final values = _history[_selectedTrend]!;
    final spots = <FlSpot>[
      for (int i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
    ];

    double minY = cfg.minY, maxY = cfg.maxY;
    if (values.isNotEmpty) {
      final lo = values.reduce((a, b) => a < b ? a : b);
      final hi = values.reduce((a, b) => a > b ? a : b);
      final pad = ((hi - lo) * 0.2).clamp(cfg.minPad, double.infinity);
      minY = lo - pad;
      maxY = hi + pad;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: cfg.color.withOpacity(0.10),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.show_chart_rounded, color: cfg.color, size: 20),
            const SizedBox(width: 8),
            const Text('Live Trend',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E))),
            const Spacer(),
            Text('last ${values.length} readings',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final name in _trendSeries.keys)
                ChoiceChip(
                  label: Text(name, style: const TextStyle(fontSize: 11)),
                  selected: name == _selectedTrend,
                  selectedColor: _trendSeries[name]!.color.withOpacity(0.18),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _selectedTrend = name),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 180,
            child: spots.length < 2
                ? Center(
                    child: Text('Waiting for readings...',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12)))
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: (_maxPoints - 1).toDouble(),
                      minY: minY,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                            color: Colors.grey.shade200, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 38,
                            getTitlesWidget: (v, meta) => Text(
                              v.toStringAsFixed(cfg.decimals),
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey.shade500),
                            ),
                          ),
                        ),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touched) => touched
                              .map((t) => LineTooltipItem(
                                    '${t.y.toStringAsFixed(cfg.decimals)} ${cfg.unit}',
                                    const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600),
                                  ))
                              .toList(),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.2,
                          color: cfg.color,
                          barWidth: 2.5,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                              show: true, color: cfg.color.withOpacity(0.10)),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _diabRiskCard() {
    final riskPct = (diabRisk * 100).clamp(0, 100);
    final color = riskPct > 65
        ? const Color(0xFFE53935)
        : riskPct > 40
            ? const Color(0xFFE65100)
            : const Color(0xFF2E7D32);
    final bg = riskPct > 65
        ? const Color(0xFFFFEBEE)
        : riskPct > 40
            ? const Color(0xFFFFF3E0)
            : const Color(0xFFE8F5E9);
    final label = riskPct > 65
        ? 'High Risk'
        : riskPct > 40
            ? 'Moderate'
            : 'Low Risk';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: color.withOpacity(0.10),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration:
                BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.health_and_safety_rounded, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Diabetes Risk',
                    style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(20)),
                  child: Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text('${riskPct.toStringAsFixed(1)}%',
              style: TextStyle(
                  color: color,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5)),
        ],
      ),
    );
  }

  Widget _statusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          Row(children: [
            Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: connected
                      ? const Color(0xFF69F0AE)
                      : Colors.orange,
                  shape: BoxShape.circle,
                )),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Live — updating every 5 seconds',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                const Icon(Icons.person_outline, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text('${widget.patient.id}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
              Row(children: [
                const Icon(Icons.cloud_done_outlined,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                const Text('Firebase — Singapore',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
            ],
          ),
        ],
      ),
    );
  }
}
