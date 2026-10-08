import 'errors.dart';

bool androidSerial(Object? value) => value is String && RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$').hasMatch(value);

typedef FlutterTarget = ({String device, String id, bool android, bool web, List<String> args});

/// The prefix makes mobile transport explicit; Flutter receives the exact serial.
FlutterTarget flutterTarget([String device = 'web-server', int webPort = 5186]) {
  if (device.startsWith('android:') && androidSerial(device.substring(8))) {
    final id = device.substring(8);
    return (device: device, id: id, android: true, web: false, args: ['-d', id]);
  }
  if (!const ['web-server', 'linux'].contains(device)) {
    throw const MomentsError('Supported Moments devices: web-server, linux, android:<exact-adb-serial>.');
  }
  final web = device == 'web-server';
  return (
    device: device,
    id: device,
    android: false,
    web: web,
    args: [
      '-d',
      device,
      if (web) ...['--web-hostname=127.0.0.1', '--web-port=$webPort'],
    ],
  );
}
