import 'dart:convert';
import 'package:http/http.dart' as http;

class RosApi {
  final http.Client client;
  final Uri base;
  final String token;
  final String clientId;
  int _sequence = 0;

  RosApi(this.client, String address, this.token, {String? clientId})
    : base = parseAddress(address),
      clientId = clientId ?? DateTime.now().microsecondsSinceEpoch.toString();

  static Uri parseAddress(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path)) {
      throw const FormatException(
        'Enter a host URL such as http://192.168.1.20:8766',
      );
    }
    return uri;
  }

  Future<Map<String, dynamic>> _request(
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    final headers = {
      'Authorization': 'Bearer ${token.trim()}',
      'Content-Type': 'application/json',
    };
    final uri = base.replace(path: path);
    final response =
        await (data == null
                ? client.get(uri, headers: headers)
                : client.post(uri, headers: headers, body: jsonEncode(data)))
            .timeout(const Duration(seconds: 8));
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected response from ROS host');
    }
    if (response.statusCode != 200) {
      throw Exception(
        decoded['error'] ?? 'ROS host returned ${response.statusCode}',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> status() => _request('/status');
  Future<Map<String, dynamic>> heartbeat() =>
      _request('/heartbeat', {'client_id': clientId});
  Future<Map<String, dynamic>> _command(
    String path,
    Map<String, dynamic> data,
  ) =>
      _request(path, {...data, 'client_id': clientId, 'sequence': ++_sequence});
  Future<Map<String, dynamic>> navigate(double x, double y) =>
      _command('/navigate', {'x': x, 'y': y});
  Future<Map<String, dynamic>> manual(String action) =>
      _command('/manual', {'action': action});
  Future<Map<String, dynamic>> stop() => _command('/stop', {});
}
