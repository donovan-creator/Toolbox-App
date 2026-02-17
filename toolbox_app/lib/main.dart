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
  final String espBaseUrl = 'http://172.20.10.3'; // ESP8266 IP (hotspot)
  final String cloudUrl = 'https://wheelz-cloud.onrender.com/update'; // Render cloud server

  // Telemetry
  int leftCount = 0;
  int rightCount = 0;
  Map<String, dynamic> imuData = {};

  // Control / logging
  ControlMode mode = ControlMode.manual;
  String currentAction = "stop"; // what is being applied right now
  String lastCloudAction = "none";

  Timer? updateTimer;

  // Tick rate: 5 Hz = every 200ms. (You can try 100ms for 10 Hz later.)
  static const Duration tick = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    updateTimer = Timer.periodic(tick, (_) => syncWithCloud());
  }

  @override
  void dispose() {
    updateTimer?.cancel();
    super.dispose();
  }

  // ==== Fetch from ESP ====
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
        setState(() {
          leftCount = left;
          rightCount = right;
          imuData = decodedImu;
        });
      }
    } catch (e) {
      debugPrint('Error fetching ESP data: $e');
    }
  }

  // ==== Execute a command on ESP ====
  Future<void> sendEspCommand(String cmd) async {
    try {
      await http
          .get(Uri.parse('$espBaseUrl/$cmd'))
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('ESP command error ($cmd): $e');
    }
  }

  // ==== Cloud sync (logging always; control only in auto mode) ====
  Future<void> syncWithCloud() async {
    await fetchESPData();

    // Build payload that is training-ready
    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'imu': imuData,
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
        // Safety stop only in auto mode
        if (mode == ControlMode.auto) {
          await sendEspCommand('stop');
          setState(() => currentAction = 'stop');
        }
        return;
      }

      final decoded = jsonDecode(response.body);
      final action = decoded['action'];

      // Always show what cloud wanted (for debugging)
      if (action != null) {
        setState(() => lastCloudAction = action.toString());
      }

      // IMPORTANT: only execute returned action in AUTO mode
      if (mode == ControlMode.auto) {
        final String act = (action ?? 'none').toString();

        // Treat these as "no-op"
        if (act.isEmpty || act == 'none' || act == 'null') {
          return;
        }

        // If your ESP uses endpoints /forward, /backward, /left, /right, /stop
        // make sure the server returns exactly those strings.
        await sendEspCommand(act);

        setState(() {
          currentAction = act;
        });

        debugPrint('AUTO: Executed cloud action: $act');
      } else {
        // Manual mode: do not execute cloud actions
        debugPrint('MANUAL: Logged telemetry (cloud action ignored)');
      }
    } catch (e) {
      debugPrint('Error syncing with cloud: $e');

      // Safety stop only in auto mode
      if (mode == ControlMode.auto) {
        await sendEspCommand('stop');
        setState(() => currentAction = 'stop');
      }
    }
  }

  // ==== Manual buttons ====
  Widget buildControlButton(String label, String command) {
    return GestureDetector(
      onTapDown: (_) async {
        // In manual mode, manual buttons drive the robot.
        // In auto mode, you can either ignore presses or allow them as an override.
        if (mode == ControlMode.manual) {
          setState(() => currentAction = command);
          await sendEspCommand(command);
        }
      },
      onTapUp: (_) async {
        if (mode == ControlMode.manual) {
          setState(() => currentAction = 'stop');
          await sendEspCommand('stop');
        }
      },
      onTapCancel: () async {
        if (mode == ControlMode.manual) {
          setState(() => currentAction = 'stop');
          await sendEspCommand('stop');
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

  // ==== UI ====
  @override
  Widget build(BuildContext context) {
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
                  setState(() {
                    mode = v ? ControlMode.auto : ControlMode.manual;
                    // If switching to manual, ensure robot isn't still moving from auto
                    // (optional but safer)
                  });

                  if (mode == ControlMode.manual) {
                    setState(() => currentAction = 'stop');
                    await sendEspCommand('stop');
                  }
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
              const Text(
                'Telemetry',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text('Mode: ${mode == ControlMode.manual ? "manual" : "auto"}'),
              Text('Left Encoder: $leftCount'),
              Text('Right Encoder: $rightCount'),
              Text('IMU: $imuData'),
              Text('Current Action (logged): $currentAction',
                  style: const TextStyle(color: Colors.lightGreenAccent)),
              Text('Last Cloud Action: $lastCloudAction',
                  style: const TextStyle(color: Colors.amber)),
              const SizedBox(height: 24),

              // Manual controls
              const Text('Manual Controls (disabled in Auto)',
                  style: TextStyle(fontSize: 16)),
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
