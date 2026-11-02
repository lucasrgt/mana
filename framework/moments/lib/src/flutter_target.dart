import 'errors.dart';

bool androidSerial(Object? value) => value is String && RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$').hasMatch(value);

/// A simulator UDID as `xcrun simctl` names it (uppercase hex).
bool simulatorUdid(Object? value) =>
    value is String && RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$').hasMatch(value);

typedef FlutterTarget = ({String device, String id, bool android, bool ios, bool web, List<String> args});

/// The prefix makes mobile transport explicit; Flutter receives the exact
/// serial or simulator UDID.
FlutterTarget flutterTarget([String device = 'web-server', int webPort = 5186]) {
  if (device.startsWith('android:') && androidSerial(device.substring(8))) {
    final id = device.substring(8);
    return (device: device, id: id, android: true, ios: false, web: false, args: ['-d', id]);
  }
  if (device.startsWith('ios:') && simulatorUdid(device.substring(4))) {
    final id = device.substring(4);
    return (device: device, id: id, android: false, ios: true, web: false, args: ['-d', id]);
  }
  if (!const ['web-server', 'linux', 'macos'].contains(device)) {
    throw const MomentsError(
      'Supported Moments devices: web-server, linux, macos, android:<exact-adb-serial>, ios:<simulator-udid>.',
    );
  }
  final web = device == 'web-server';
  return (
    device: device,
    id: device,
    android: false,
    ios: false,
    web: web,
    args: [
      '-d',
      device,
      if (web) ...['--web-hostname=127.0.0.1', '--web-port=$webPort'],
    ],
  );
}
