import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'ros_api.dart';

void main() => runApp(const RobotApp());

class RobotApp extends StatelessWidget {
  const RobotApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wheelz Controller',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blueAccent,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const RobotHomePage(),
  );
}

enum ControlMode { manual, automatic }

class RobotHomePage extends StatefulWidget {
  final http.Client? client;
  const RobotHomePage({super.key, this.client});
  @override
  State<RobotHomePage> createState() => _RobotHomePageState();
}

class _RobotHomePageState extends State<RobotHomePage>
    with WidgetsBindingObserver {
  late final http.Client _client = widget.client ?? http.Client();
  final _host = TextEditingController();
  final _token = TextEditingController();
  final _esp = TextEditingController(text: 'http://172.20.10.3');
  final _x = TextEditingController();
  final _y = TextEditingController();
  final _goalForm = GlobalKey<FormState>();
  RosApi? _api;
  ControlMode _mode = ControlMode.manual;
  Map<String, dynamic>? _status;
  Map<String, dynamic> _imu = {};
  int _left = 0, _right = 0, _version = 0;
  bool _busy = false, _polling = false, _manualSending = false;
  bool _reachable = false, _calibrating = false;
  String? _error, _held;
  String _action = 'stop';
  String _runId = DateTime.now().toIso8601String();
  double _biasX = 0, _biasY = 0, _biasZ = 0;
  Timer? _pollTimer, _holdTimer;
  Future<void> _directQueue = Future.value();

  bool get _navigating => _status?['active'] == true;
  bool get _ready => _reachable && _status?['ready'] == true;
  bool get _manualEnabled =>
      !_busy &&
      _mode == ControlMode.manual &&
      !_calibrating &&
      (_api == null || (_reachable && _status?['connected'] == true));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _poll(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _holdTimer?.cancel();
    if (_api != null) {
      unawaited(_api!.stop().catchError((Object _) => <String, dynamic>{}));
    }
    for (final controller in [_host, _token, _esp, _x, _y]) {
      controller.dispose();
    }
    if (widget.client == null) _client.close();
    super.dispose();
  }

  String _message(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  Future<void> _poll() async {
    if (_polling || _busy || _calibrating) return;
    _polling = true;
    final version = _version;
    try {
      final api = _api;
      if (api != null) {
        final status = _navigating ? await api.heartbeat() : await api.status();
        if (mounted && version == _version) {
          setState(() {
            _status = status;
            _reachable = true;
          });
        }
      } else if (_mode == ControlMode.manual) {
        final base = RosApi.parseAddress(_esp.text);
        final counts = await _client
            .get(base.replace(path: '/counts'))
            .timeout(const Duration(seconds: 2));
        final imu = await _client
            .get(base.replace(path: '/imu'))
            .timeout(const Duration(seconds: 2));
        final match = RegExp(
          r'Left:\s*(-?\d+)\s*\|\s*Right:\s*(-?\d+)',
        ).firstMatch(counts.body);
        final decoded = jsonDecode(imu.body);
        if (counts.statusCode != 200 ||
            imu.statusCode != 200 ||
            match == null ||
            decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid ESP sensor response');
        }
        if (mounted && version == _version) {
          setState(() {
            _left = int.parse(match.group(1)!);
            _right = int.parse(match.group(2)!);
            _imu = decoded;
          });
        }
        // Preserve manual dataset logging. Cloud responses never command motors.
        final corrected = {
          ...decoded,
          'gx': ((decoded['gx'] as num?)?.toDouble() ?? 0) - _biasX,
          'gy': ((decoded['gy'] as num?)?.toDouble() ?? 0) - _biasY,
          'gz': ((decoded['gz'] as num?)?.toDouble() ?? 0) - _biasZ,
        };
        await _client
            .post(
              Uri.parse('https://wheelz-cloud.onrender.com/update'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'runId': _runId,
                'imu': corrected,
                'counts': {'left': _left, 'right': _right},
                'action': _action,
                'mode': 'manual',
              }),
            )
            .timeout(const Duration(seconds: 3));
      }
    } catch (error) {
      if (mounted && version == _version && _api != null) {
        setState(() {
          _reachable = false;
          _error = 'Host unavailable: ${_message(error)}';
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    ++_version;
    try {
      if (_token.text.trim().isEmpty) {
        throw const FormatException('Enter the pairing token from your PC');
      }
      if (_held != null) await _direct('stop');
      final api = RosApi(_client, _host.text, _token.text);
      final status = await api.status();
      if (status['api_version'] != 1) {
        throw const FormatException('Unsupported ROS host version');
      }
      if (mounted) {
        setState(() {
          _api = api;
          _status = status;
          _reachable = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (!await _stop()) return;
    ++_version;
    if (mounted) {
      setState(() {
        _api = null;
        _status = null;
        _reachable = false;
      });
    }
  }

  Future<void> _switchMode(ControlMode value) async {
    if (_busy || value == _mode) return;
    if ((_held != null || _navigating || _api != null) && !await _stop()) {
      return;
    }
    ++_version;
    if (mounted) {
      setState(() {
        _mode = value;
        _error = null;
      });
    }
  }

  Future<void> _direct(String action) {
    final base = RosApi.parseAddress(_esp.text);
    final commandVersion = _version;
    _directQueue = _directQueue.catchError((Object _) {}).then((_) async {
      if (action != 'stop' &&
          (commandVersion != _version || _held != action || _api != null)) {
        return;
      }
      try {
        final response = await _client
            .get(base.replace(path: '/$action'))
            .timeout(const Duration(milliseconds: 700));
        if (response.statusCode != 200) {
          throw Exception('ESP returned ${response.statusCode}');
        }
      } on TimeoutException {
        if (action != 'left' && action != 'right') rethrow;
        // Existing ESP turn routes do not return a response.
      } on http.ClientException {
        if (action != 'left' && action != 'right') rethrow;
      }
    });
    return _directQueue;
  }

  void _press(String action) {
    if (!_manualEnabled) return;
    setState(() {
      _held = action;
      _action = action;
      _error = null;
    });
    unawaited(_sendHeld());
    _holdTimer?.cancel();
    if (_api != null) {
      _holdTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _sendHeld(),
      );
    }
  }

  Future<void> _sendHeld() async {
    final action = _held;
    if (action == null || _manualSending) return;
    _manualSending = true;
    try {
      if (_api == null) {
        await _direct(action);
      } else {
        await _api!.manual(action);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
      _held = null;
      _holdTimer?.cancel();
      unawaited(_stop());
    } finally {
      _manualSending = false;
    }
  }

  Future<bool> _stop() async {
    ++_version;
    _held = null;
    _holdTimer?.cancel();
    if (mounted) {
      setState(() {
        _action = 'stop';
        _busy = true;
      });
    }
    try {
      final api = _api;
      if (api != null) {
        final status = await api.stop();
        if (mounted) {
          setState(() {
            _status = status;
            _reachable = true;
            _error = null;
          });
        }
      } else {
        await _direct('stop');
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Stop not confirmed: ${_message(error)}');
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _coordinate(String? value) {
    final number = double.tryParse(value?.trim() ?? '');
    return number == null || !number.isFinite
        ? 'Enter a finite number in metres'
        : null;
  }

  Future<void> _navigate() async {
    if (!_goalForm.currentState!.validate() ||
        !_ready ||
        _busy ||
        _navigating) {
      return;
    }
    final x = double.parse(_x.text.trim()), y = double.parse(_y.text.trim());
    final position = _status?['position'] as Map<String, dynamic>?;
    if (position == null ||
        math.sqrt(
              math.pow(x - (position['x'] as num), 2) +
                  math.pow(y - (position['y'] as num), 2),
            ) >
            4) {
      setState(
        () => _error = 'Choose a goal within 4 metres of the current position.',
      );
      return;
    }
    final version = ++_version;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await _api!.navigate(x, y);
      if (mounted && version == _version) setState(() => _status = status);
    } catch (error) {
      if (mounted && version == _version) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && version == _version) setState(() => _busy = false);
    }
  }

  Future<void> _calibrate() async {
    if (_api != null || _held != null || _calibrating) return;
    setState(() => _calibrating = true);
    final sums = [0.0, 0.0, 0.0];
    var count = 0;
    try {
      final base = RosApi.parseAddress(_esp.text);
      for (var i = 0; i < 20; i++) {
        final response = await _client
            .get(base.replace(path: '/imu'))
            .timeout(const Duration(seconds: 2));
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        for (var axis = 0; axis < 3; axis++) {
          sums[axis] += (data[['gx', 'gy', 'gz'][axis]] as num).toDouble();
        }
        count++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted) return;
      }
      if (mounted) {
        setState(() {
          _biasX = sums[0] / count;
          _biasY = sums[1] / count;
          _biasZ = sums[2] / count;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Calibration failed: ${_message(error)}');
      }
    } finally {
      if (mounted) setState(() => _calibrating = false);
    }
  }

  Widget _driveButton(String label, String action, IconData icon) => Semantics(
    button: true,
    label: label,
    enabled: _manualEnabled,
    child: GestureDetector(
      onTapDown: _manualEnabled ? (_) => _press(action) : null,
      onTapUp: (_) => _stop(),
      onTapCancel: () => _stop(),
      child: Container(
        width: 120,
        height: 72,
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: _manualEnabled
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.white12,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Icon(icon), Text(label)],
        ),
      ),
    ),
  );

  Widget _hostCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ROS host', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Your PC runs the model. Keep it on the same network as the robot and phone.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            enabled: _api == null && !_busy,
            decoration: const InputDecoration(
              labelText: 'PC address',
              hintText: 'http://192.168.1.20:8766',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            enabled: _api == null && !_busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Pairing token',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : (_api == null ? _connect : _disconnect),
            icon: Icon(_api == null ? Icons.link : Icons.link_off),
            label: Text(_api == null ? 'Connect to PC' : 'Stop and disconnect'),
          ),
          Text(
            _api == null
                ? 'Not connected to ROS'
                : (_reachable
                      ? 'Connected to ROS host'
                      : 'ROS host unavailable'),
          ),
        ],
      ),
    ),
  );

  Widget _automatic() {
    final position = _status?['position'] as Map<String, dynamic>?;
    String number(String key) =>
        (position?[key] as num?)?.toStringAsFixed(2) ?? '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _hostCard(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Navigate to a goal',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Coordinates are in metres from the odometry start point: +X forward, +Y left at startup. They stay fixed when the robot turns.',
                ),
                const SizedBox(height: 12),
                Text('Position: X ${number('x')} m   Y ${number('y')} m'),
                Text('Navigation: ${_status?['status'] ?? 'Not connected'}'),
                if (_api != null && !_ready)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Not ready: the robot must be online with calibrated, fresh odometry.',
                      style: TextStyle(color: Colors.amber),
                    ),
                  ),
                const SizedBox(height: 16),
                Form(
                  key: _goalForm,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _x,
                          validator: _coordinate,
                          enabled: !_busy && !_navigating,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'X (metres)',
                            hintText: '1.0',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _y,
                          validator: _coordinate,
                          enabled: !_busy && !_navigating,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Y (metres)',
                            hintText: '0.0',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _ready && !_busy && !_navigating
                      ? _navigate
                      : null,
                  icon: const Icon(Icons.navigation),
                  label: Text(_navigating ? 'Navigating…' : 'Navigate'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Maximum goal distance: 4 m. No obstacle avoidance. Test in a clear area after calibration.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _manual() => Column(
    children: [
      Text(
        _api == null
            ? 'Direct ESP manual control'
            : 'Manual control through ROS',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (_api == null) ...[
        TextField(
          controller: _esp,
          enabled: _held == null && !_busy,
          decoration: const InputDecoration(labelText: 'ESP8266 address'),
        ),
        const Text(
          'Stop the ROS host before using direct control. Its stop commands can conflict with this mode.',
        ),
        Text('Left encoder: $_left    Right encoder: $_right'),
        Text('IMU: $_imu'),
        Text('Run: $_runId', style: Theme.of(context).textTheme.bodySmall),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () =>
                  setState(() => _runId = DateTime.now().toIso8601String()),
              child: const Text('New run'),
            ),
            TextButton(
              onPressed: _calibrating || _busy ? null : _calibrate,
              child: Text(_calibrating ? 'Calibrating…' : 'Calibrate gyro'),
            ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      const Text('Hold a direction to move; release to stop.'),
      _driveButton('Forward', 'forward', Icons.arrow_upward),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _driveButton('Left', 'left', Icons.arrow_back),
          _driveButton('Right', 'right', Icons.arrow_forward),
        ],
      ),
      _driveButton('Backward', 'backward', Icons.arrow_downward),
      Text('Action: $_action'),
      const SizedBox(height: 12),
      ExpansionTile(
        title: const Text('PC connection for ROS control'),
        children: [_hostCard()],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Wheelz Controller')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<ControlMode>(
                segments: const [
                  ButtonSegment(
                    value: ControlMode.manual,
                    label: Text('Manual'),
                    icon: Icon(Icons.gamepad),
                  ),
                  ButtonSegment(
                    value: ControlMode.automatic,
                    label: Text('Automatic'),
                    icon: Icon(Icons.navigation),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (values) => _switchMode(values.first),
              ),
              const SizedBox(height: 16),
              _mode == ControlMode.manual ? _manual() : _automatic(),
            ],
          ),
        ),
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: () => _stop(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade800,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(54),
                  ),
                  label: const Text('CANCEL / STOP'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Stopping needs a working connection. Keep a physical power cutoff accessible.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
