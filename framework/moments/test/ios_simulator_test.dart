import 'dart:io';

import 'package:moments/src/ios_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// The transport against a real booted simulator and the real `xcrun simctl`
/// (CI's macOS job boots one and sets MOMENTS_IOS_SIMULATOR to its UDID).
void main() {
  final udid = Platform.environment['MOMENTS_IOS_SIMULATOR'];

  test('a booted simulator is claimed once, read through the real simctl, and released', () async {
    final root = temporary('mana-ios-real-');
    final claims = p.join(root, 'claims');
    IosTransport transport(String name) =>
        IosTransport(directory: p.join(root, name), device: udid!, ports: const [38101], claims: claims);

    final first = transport('one');
    final state = await first.start();
    expect(state['phase'], 'ready');
    expect(state['runtime'], contains('.iOS-'));
    expect(state['boot'], isA<String>());

    await expectLater(transport('two').start(), throwsA(predicate((e) => '$e'.contains('claimed by another run'))));

    expect((await first.close())['phase'], 'disposed');
    expect(Directory(claims).listSync(), isEmpty);
    expect((await transport('three').start())['phase'], 'ready');
  }, skip: udid == null ? 'MOMENTS_IOS_SIMULATOR names no booted simulator' : false);
}
