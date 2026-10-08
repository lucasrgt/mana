import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState;
import 'package:moments/src/errors.dart';
import 'package:moments/src/layers.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

const layer = PrivateJsonLayer();
final opts = LayerOptions(assertStopped: (_) {});

({String home, String initial}) setup() {
  final home = temporary('mana-private-json-');
  final initial = p.join(home, 'initial');
  Directory(initial).createSync();
  Process.runSync('chmod', ['700', initial]);
  savePrivateState(p.join(initial, 'state.json'), {'messages': <Object?>[]});
  return (home: home, initial: initial);
}

void main() {
  test('private captured state forks independently and preserves opaque capabilities', () async {
    final (:home, :initial) = setup();
    final root = p.join(home, 'root');
    await layer.capture(handle: PrivateJsonLayer.sourceHandle(initial), out: root, opts: opts);
    final first = await layer.materialize(from: root, dir: p.join(home, 'a'));
    final second = await layer.materialize(from: root, dir: p.join(home, 'b'));
    PrivateJsonLayer.writeState(first, {
      'messages': [
        {'capability': 'synthetic-private-value'},
      ],
    });
    expect(PrivateJsonLayer.readState(second), {'messages': <Object?>[]});
    final captured = p.join(home, 'captured');
    await layer.capture(handle: first, out: captured, opts: opts);
    final restored = await layer.materialize(from: captured, dir: p.join(home, 'restored'));
    expect(PrivateJsonLayer.readState(restored), PrivateJsonLayer.readState(first));
    await expectLater(
      layer.capture(
        handle: first,
        out: p.join(home, 'live'),
        opts: LayerOptions(assertStopped: (_) => throw const MomentsError('writer active')),
      ),
      throwing('writer active'),
    );
    expect(Directory(p.join(home, 'live')).existsSync(), isFalse);
    for (final handle in [first, second, restored]) {
      await layer.dispose(handle: handle, opts: opts);
    }
    expect(File(p.join(first['dir']! as String, 'state.json')).existsSync(), isFalse);
    await layer.forget(dir: root);
    await layer.forget(dir: captured);
  });

  test('snapshot tampering, public files, symbolic paths and unknown disposal entries are refused', () async {
    final (:home, :initial) = setup();
    final root = p.join(home, 'root');
    await layer.capture(handle: PrivateJsonLayer.sourceHandle(initial), out: root, opts: opts);
    final handle = await layer.materialize(from: root, dir: p.join(home, 'actor'));
    final dir = handle['dir']! as String;
    savePrivateState(p.join(root, 'state.json'), {'changed': true});
    await expectLater(layer.materialize(from: root, dir: p.join(home, 'tampered')), throwing('changed'));
    Process.runSync('chmod', ['644', p.join(dir, 'state.json')]);
    expect(() => PrivateJsonLayer.readState(handle), throwing('Invalid private JSON file'));
    Process.runSync('chmod', ['600', p.join(dir, 'state.json')]);
    final link = p.join(home, 'link');
    Link(link).createSync(initial);
    expect(() => PrivateJsonLayer.sourceHandle(link), throwing('real and private'));
    expect(() => PrivateJsonLayer.writeState(handle, {'tooLarge': 'x' * (1024 * 1024)}), throwing('bounded'));
    final before = File(p.join(dir, 'state.json')).readAsStringSync();
    expect(() => PrivateJsonLayer.writeState(handle, {'many': List.filled(200000, 0)}), throwing('bounded'));
    expect(File(p.join(dir, 'state.json')).readAsStringSync(), before);
    File(p.join(dir, 'foreign')).writeAsStringSync('preserve');
    await expectLater(layer.dispose(handle: handle, opts: opts), throwing('Unexpected'));
    expect(File(p.join(dir, 'state.json')).existsSync(), isTrue);
    expect(File(p.join(dir, 'foreign')).readAsStringSync(), 'preserve');
  });

  test('recovery refuses live creators, recovers partial state and is repeatable', () async {
    final (:home, :initial) = setup();
    final root = p.join(home, 'root');
    await layer.capture(handle: PrivateJsonLayer.sourceHandle(initial), out: root, opts: opts);
    final handle = await layer.materialize(from: root, dir: p.join(home, 'actor'));
    final dir = handle['dir']! as String;
    await expectLater(layer.recover(dir: dir, opts: opts), throwing('creator is alive'));
    final metadata = p.join(dir, 'private-json-layer.json');
    savePrivateState(metadata, {...(readJson(metadata)! as Map).cast<String, Object?>(), 'phase': 'attention'});
    expect((await layer.recover(dir: dir, opts: opts, pending: true))['status'], 'disposed');
    expect((await layer.recover(dir: dir, opts: opts))['status'], 'disposed');
    expect(File(p.join(dir, 'state.json')).existsSync(), isFalse);
    final empty = p.join(home, 'empty');
    Directory(empty).createSync();
    Process.runSync('chmod', ['700', empty]);
    expect((await layer.recover(dir: empty, pending: true, opts: opts))['status'], 'disposed');
  });
}
