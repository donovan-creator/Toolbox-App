import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox_app/main.dart';
import 'package:toolbox_app/ros_api.dart';

void main() {
  test('API validates address and orders motor mutations after stop', () async {
    final requests = <Map<String, dynamic>>[];
    final api = RosApi(
      MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        expect(request.headers['Authorization'], 'Bearer test-token');
        return http.Response('{}', 200);
      }),
      'http://localhost:8766',
      'test-token',
      clientId: 'test',
    );
    await api.navigate(1, -0.5);
    await api.stop();
    await api.manual('forward');
    expect(requests.map((request) => request['sequence']), [1, 2, 3]);
    expect(requests.first['x'], 1);
    expect(requests.first['y'], -0.5);
    for (final bad in ['robot', 'http://user:pass@host', 'http://host/path']) {
      expect(() => RosApi.parseAddress(bad), throwsFormatException);
    }
  });

  testWidgets(
    'Automatic validates goals, navigates, stops, and returns to Manual',
    (tester) async {
      final commands = <String>[];
      final bodies = <Map<String, dynamic>>[];
      var active = false;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          commands.add(request.url.path);
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (request.url.path == '/navigate') active = true;
          if (request.url.path == '/stop') active = false;
        }
        return http.Response(
          jsonEncode({
            'api_version': 1,
            'connected': true,
            'ready': true,
            'active': active,
            'status': active ? 'navigating' : 'disabled',
            'position': {'x': 0.0, 'y': 0.0, 'yaw': 0.0},
          }),
          200,
        );
      });
      await tester.pumpWidget(MaterialApp(home: RobotHomePage(client: client)));
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      expect(find.text('Navigate to a goal'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(0),
        'http://localhost:8766',
      );
      await tester.enterText(find.byType(TextField).at(1), 'test-token');
      await tester.ensureVisible(find.text('Connect to PC'));
      await tester.tap(find.text('Connect to PC'));
      await tester.pumpAndSettle();
      expect(find.text('Connected to ROS host'), findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(find.text('Navigate')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Navigate'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a finite number in metres'), findsNWidgets(2));
      await tester.enterText(find.byType(TextFormField).at(0), '5');
      await tester.enterText(find.byType(TextFormField).at(1), '0');
      await Scrollable.ensureVisible(
        tester.element(find.text('Navigate')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Navigate'));
      await tester.pumpAndSettle();
      expect(commands, isNot(contains('/navigate')));
      expect(find.textContaining('within 4 metres'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), '1');
      await tester.enterText(find.byType(TextFormField).at(1), '-0.5');
      await Scrollable.ensureVisible(
        tester.element(find.text('Navigate')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Navigate'));
      await tester.pumpAndSettle();
      expect(commands, contains('/navigate'));
      expect(bodies[commands.indexOf('/navigate')]['y'], -0.5);
      expect(find.text('Navigating…'), findsOneWidget);
      await tester.ensureVisible(find.text('CANCEL / STOP'));
      await tester.tap(find.text('CANCEL / STOP'));
      await tester.pumpAndSettle();
      expect(commands.last, '/stop');
      await tester.scrollUntilVisible(
        find.text('Manual'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(find.text('Manual control through ROS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('No calibration keeps Navigate disabled', (tester) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'api_version': 1,
          'connected': true,
          'ready': false,
          'active': false,
          'status': 'disabled',
          'position': null,
        }),
        200,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: RobotHomePage(client: client)));
    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).at(0),
      'http://localhost:8766',
    );
    await tester.enterText(find.byType(TextField).at(1), 'test-token');
    await tester.tap(find.text('Connect to PC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not ready:'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find
          .ancestor(
            of: find.text('Navigate'),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          )
          .first,
    );
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
