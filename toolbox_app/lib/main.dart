import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';

void main() {
  runApp(const RobotApp());
}

class RobotApp extends StatelessWidget {
  const RobotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wheelz Cloud Controller',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
      ),
      home: const RobotHomePage(),
    );
  }
}

enum ControlMode { manual, auto }

class RobotHomePage extends StatefulWidget {
  const RobotHomePage({super.key});

  @override
  State<RobotHomePage> createState() => _RobotHomePageState();
}

class _RobotHomePageState extends State<RobotHomePage> {
  final String espBaseUrl = 'http://172.20.10.3';
  final String cloudUrl = 'https://wheelz-cloud.onrender.com/update';

  // Telemetry
  int leftCount = 0;
  int rightCount = 0;
  Map<String, dynamic> imuData = {};

  // Control / logging
  ControlMode mode = ControlMode.manual;
  String currentAction = "stop";      // what we are applying/logging
  String lastCloudAction = "none";    // what cloud most recently suggested
  String lastSentEspAction = "none";  // what we actually sent to ESP last (dedupe)

  // Session tagging for datasets
  String runId = DateTime.now().toIso8601String();

  // Gyro bias calibration (optional, but helpful)
  bool isCalibrating = false;
  double biasGx = 0.0, biasGy = 0.0, biasGz = 0.0;

  Timer? updateTimer;

  static const allowedActions = {"forward", "backward", "left", "right", "stop"};

  // Tick rates: manual logging slower; auto control faster
  static const Duration manualTick = Duration(milliseconds: 500); // 2 Hz
  static const Duration autoTick = Duration(milliseconds: 200);   // 5 Hz

  @override
  void initState() {
    super.initState();
    _startTimerForMode();
  }

  @override
  void dispose() {
    updateTimer?.cancel();
    super.dispose();
  }

  void _startTimerForMode() {
    updateTimer?.cancel();
    final interval = (mode == ControlMode.manual) ? manualTick : autoTick;
    updateTimer = Timer.periodic(interval, (_) => syncWithCloud());
  }

  Future<void> fetchESPData() async {
    try {
      final countsResponse = await http
          .get(Uri.parse('$espBaseUrl/counts'))
          .timeout(const Duration(seconds: 2));

      final imuResponse = await http
          .get(Uri.parse('$espBaseUrl/imu'))
          .timeout(const Duration(seconds: 2));

      final counts = countsResponse.body.split('|');

      final left =
          int.tryParse(counts[0].replaceAll(RegExp(r'[^0-9\-]'), '')) ??
              leftCount;
      final right =
          int.tryParse(counts[1].replaceAll(RegExp(r'[^0-9\-]'), '')) ??
              rightCount;

      final decodedImu = jsonDecode(imuResponse.body);
      if (decodedImu is Map<String, dynamic>) {
        if (!mounted) return;
        setState(() {
          leftCount = left;
          rightCount = right;
          imuData = decodedImu;
        });
      }
    } catch (e) {
      debugPrint('Error fetching ESP data: $e');
      // Safety: if we can’t read sensors in AUTO, stop
      if (mode == ControlMode.auto) {
        await sendEspCommand('stop');
        if (mounted) setState(() => currentAction = 'stop');
      }
    }
  }

  Future<void> sendEspCommand(String cmd) async {
    try {
      await http
          .get(Uri.parse('$espBaseUrl/$cmd'))
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('ESP command error ($cmd): $e');
    }
  }

  Map<String, dynamic> _biasCorrectImu(Map<String, dynamic> imu) {
    // Keep same keys; just bias-correct gx/gy/gz if present.
    double gx = (imu["gx"] is num) ? (imu["gx"] as num).toDouble() : 0.0;
    double gy = (imu["gy"] is num) ? (imu["gy"] as num).toDouble() : 0.0;
    double gz = (imu["gz"] is num) ? (imu["gz"] as num).toDouble() : 0.0;

    return {
      ...imu,
      "gx": gx - biasGx,
      "gy": gy - biasGy,
      "gz": gz - biasGz,
    };
  }

  Future<void> syncWithCloud() async {
    await fetchESPData();

    final correctedImu = _biasCorrectImu(imuData);

    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'runId': runId, // harmless if server ignores extras
      'imu': correctedImu,
      'counts': {'left': leftCount, 'right': rightCount},
      'action': currentAction,
      'mode': (mode == ControlMode.manual) ? 'manual' : 'auto',
    };

    try {
      final response = await http
          .post(
            Uri.parse(cloudUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode != 200) {
        debugPrint('Cloud server error: ${response.statusCode}');
        if (mode == ControlMode.auto) {
          await sendEspCommand('stop');
          if (mounted) setState(() => currentAction = 'stop');
        }
        return;
      }

      final decoded = jsonDecode(response.body);
      final action = decoded['action'];

      if (action != null && mounted) {
        setState(() => lastCloudAction = action.toString());
      }

      // IMPORTANT: only execute in AUTO
      if (mode == ControlMode.auto) {
        final String act = (action ?? 'none').toString();

        // validate action
        if (!allowedActions.contains(act)) {
          // ignore unknown suggestions
          return;
        }

        // dedupe: only send when it changes
        if (act != lastSentEspAction) {
          await sendEspCommand(act);
          lastSentEspAction = act;
          if (mounted) setState(() => currentAction = act);
          debugPrint('AUTO: Executed cloud action: $act');
        }
      }
    } catch (e) {
      debugPrint('Error syncing with cloud: $e');
      if (mode == ControlMode.auto) {
        await sendEspCommand('stop');
        if (mounted) setState(() => currentAction = 'stop');
      }
    }
  }

  Future<void> calibrateGyroBias() async {
    if (isCalibrating) return;
    setState(() => isCalibrating = true);

    const int samples = 20;
    const Duration spacing = Duration(milliseconds: 100); // ~2 seconds total

    double sumGx = 0.0, sumGy = 0.0, sumGz = 0.0;
    int got = 0;

    for (int i = 0; i < samples; i++) {
      try {
        final imuResponse = await http
            .get(Uri.parse('$espBaseUrl/imu'))
            .timeout(const Duration(seconds: 2));
        final decoded = jsonDecode(imuResponse.body);
        if (decoded is Map<String, dynamic>) {
          final gx = (decoded["gx"] is num) ? (decoded["gx"] as num).toDouble() : 0.0;
          final gy = (decoded["gy"] is num) ? (decoded["gy"] as num).toDouble() : 0.0;
          final gz = (decoded["gz"] is num) ? (decoded["gz"] as num).toDouble() : 0.0;
          sumGx += gx; sumGy += gy; sumGz += gz;
          got++;
        }
      } catch (_) {}
      await Future.delayed(spacing);
    }

    if (got > 0) {
      setState(() {
        biasGx = sumGx / got;
        biasGy = sumGy / got;
        biasGz = sumGz / got;
      });
    }

    setState(() => isCalibrating = false);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Gyro bias set: gx=$biasGx, gy=$biasGy, gz=$biasGz')),
    );
  }

  Widget buildControlButton(String label, String command) {
    return GestureDetector(
      onTapDown: (_) async {
        if (mode == ControlMode.manual) {
          setState(() => currentAction = command);
          await sendEspCommand(command);
          lastSentEspAction = command; // keep in sync
        }
      },
      onTapUp: (_) async {
        if (mode == ControlMode.manual) {
          setState(() => currentAction = 'stop');
          await sendEspCommand('stop');
          lastSentEspAction = 'stop';
        }
      },
      onTapCancel: () async {
        if (mode == ControlMode.manual) {
          setState(() => currentAction = 'stop');
          await sendEspCommand('stop');
          lastSentEspAction = 'stop';
        }
      },
      child: Opacity(
        opacity: (mode == ControlMode.manual) ? 1.0 : 0.45,
        child: Container(
          width: 110,
          height: 90,
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final modeText = (mode == ControlMode.manual) ? "manual" : "auto";

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wheelz RL Controller'),
        actions: [
          Row(
            children: [
              const Text('Manual'),
              Switch(
                value: mode == ControlMode.auto,
                onChanged: (v) async {
                  setState(() => mode = v ? ControlMode.auto : ControlMode.manual);

                  // safety: stop on mode switch to manual
                  if (mode == ControlMode.manual) {
                    setState(() => currentAction = 'stop');
                    await sendEspCommand('stop');
                    lastSentEspAction = 'stop';
                  }

                  _startTimerForMode();
                },
              ),
              const Text('Auto'),
              const SizedBox(width: 12),
            ],
          )
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Telemetry', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),

              Text('Mode: $modeText'),
              Text('Run ID: $runId'),
              Text('Left Encoder: $leftCount'),
              Text('Right Encoder: $rightCount'),
              Text('IMU: $imuData'),

              Text('Current Action (logged): $currentAction',
                  style: const TextStyle(color: Colors.lightGreenAccent)),
              Text('Last Cloud Action: $lastCloudAction',
                  style: const TextStyle(color: Colors.amber)),

              const SizedBox(height: 18),

              ElevatedButton(
                onPressed: () {
                  setState(() => runId = DateTime.now().toIso8601String());
                },
                child: const Text('New Run (change runId)'),
              ),

              const SizedBox(height: 10),

              ElevatedButton(
                onPressed: isCalibrating ? null : calibrateGyroBias,
                child: Text(isCalibrating ? 'Calibrating...' : 'Calibrate Gyro Bias (2s still)'),
              ),

              const SizedBox(height: 20),

              const Text('Manual Controls (disabled in Auto)', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 8),

              buildControlButton('Forward', 'forward'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  buildControlButton('Left', 'left'),
                  buildControlButton('Right', 'right'),
                ],
              ),
              buildControlButton('Backward', 'backward'),

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: () async {
                  setState(() => currentAction = 'stop');
                  await sendEspCommand('stop');
                  lastSentEspAction = 'stop';
                },
                child: const Text('STOP'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
