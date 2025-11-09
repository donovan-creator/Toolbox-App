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

class RobotHomePage extends StatefulWidget {
  const RobotHomePage({super.key});

  @override
  State<RobotHomePage> createState() => _RobotHomePageState();
}

class _RobotHomePageState extends State<RobotHomePage> {
  final String espBaseUrl = 'http://172.20.10.3'; // ESP8266 IP (hotspot)
  final String cloudUrl = 'https://wheelz-cloud.onrender.com/update'; // Render cloud server

  int leftCount = 0;
  int rightCount = 0;
  Map<String, dynamic> imuData = {};
  String lastAction = "none";
  Timer? updateTimer;

  @override
  void initState() {
    super.initState();
    // Begin automatic RL loop
    updateTimer = Timer.periodic(const Duration(seconds: 2), (_) => syncWithCloud());
  }

  @override
  void dispose() {
    updateTimer?.cancel();
    super.dispose();
  }

  // ==== Fetch from ESP ====
  Future<void> fetchESPData() async {
    try {
      final countsResponse = await http.get(Uri.parse('$espBaseUrl/counts')).timeout(const Duration(seconds: 2));
      final imuResponse = await http.get(Uri.parse('$espBaseUrl/imu')).timeout(const Duration(seconds: 2));

      final counts = countsResponse.body.split('|');
      final left = int.tryParse(counts[0].replaceAll(RegExp(r'[^0-9\-]'), '')) ?? leftCount;
      final right = int.tryParse(counts[1].replaceAll(RegExp(r'[^0-9\-]'), '')) ?? rightCount;

      setState(() {
        leftCount = left;
        rightCount = right;
        imuData = jsonDecode(imuResponse.body);
      });
    } catch (e) {
      debugPrint('Error fetching ESP data: $e');
    }
  }

  // ==== Send to cloud (RL) and execute action ====
  Future<void> syncWithCloud() async {
    await fetchESPData();

    try {
      final response = await http.post(
        Uri.parse(cloudUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'imu': imuData,
          'counts': {'left': leftCount, 'right': rightCount},
        }),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final action = decoded['action'] ?? 'stop';
        setState(() => lastAction = action);
        await http.get(Uri.parse('$espBaseUrl/$action')).timeout(const Duration(seconds: 2));
        debugPrint('RL Action Executed: $action');
      } else {
        debugPrint('Cloud server error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error syncing with cloud: $e');
    }
  }

  // ==== Manual buttons ====
  Widget buildControlButton(String label, String command) {
    return GestureDetector(
      onTapDown: (_) => http.get(Uri.parse('$espBaseUrl/$command')),
      onTapUp: (_) => http.get(Uri.parse('$espBaseUrl/stop')),
      onTapCancel: () => http.get(Uri.parse('$espBaseUrl/stop')),
      child: Container(
        width: 100,
        height: 100,
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.blueAccent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  // ==== UI ====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wheelz RL Controller')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Telemetry', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Left Encoder: $leftCount'),
            Text('Right Encoder: $rightCount'),
            Text('IMU: $imuData'),
            Text('Last RL Action: $lastAction', style: const TextStyle(color: Colors.amber)),
            const SizedBox(height: 30),
            buildControlButton('Forward', 'forward'),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                buildControlButton('Left', 'left'),
                buildControlButton('Right', 'right'),
              ],
            ),
            buildControlButton('Backward', 'backward'),
          ],
        ),
      ),
    );
  }
}
