import 'dart:async';
import 'dart:convert';

import 'package:moments/src/errors.dart';
import 'package:moments/src/renewal.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

void main() {
  test('renewal serializes preparation and only reports ready after the new screen', () async {
    final prepared = Completer<Map<String, Object?>>(), confirm = Completer<Map<String, Object?>?>();
    Map<String, Object?>? committed;
    var held = false;
    final renewal = RenewalCoordinator(
      log: (_) {},
      acquire: (name) {
        if (name != 'checkout') throw const MomentsError('Unknown moment');
        held = true;
        return () => held = false;
      },
      prepare: (_, _) => prepared.future,
      commit: (launch) {
        expect(held, isTrue);
        committed = launch;
      },
      refresh: (_) {
        expect(held, isFalse);
        return confirm.future;
      },
    );
    expect(() => renewal.start('unknown'), throwing('Unknown'));
    expect(renewal.start('checkout')['phase'], 'preparing');
    expect(() => renewal.start('checkout'), throwing('already running'));
    prepared.complete({
      'account': {'password': 'private-bootstrap'},
      'projection': {'transactionId': 'new-reservation'},
    });
    await eventually(() => renewal.status()['phase'] == 'restoring');
    expect((committed!['projection']! as Map)['transactionId'], 'new-reservation');
    expect(jsonEncode(renewal.status()).contains('private-bootstrap'), isFalse);
    expect(renewal.status()['dataPrepared'], true);
    confirm.complete({'phase': 'ready'});
    await eventually(() => renewal.status()['phase'] == 'ready');
    expect(renewal.status()['totalMs'] as num, greaterThanOrEqualTo(renewal.status()['prepareMs']! as num));
  });

  test('preparation failure preserves the old launch and does not retry automatically', () async {
    var calls = 0, commits = 0, held = false;
    final renewal = RenewalCoordinator(
      log: (_) {},
      acquire: (_) {
        held = true;
        return () => held = false;
      },
      prepare: (_, _) async {
        calls++;
        throw const MomentsError('API rejected the reservation');
      },
      commit: (_) => commits++,
      refresh: (_) async => {'phase': 'ready'},
    );
    renewal.start('checkout');
    await eventually(() => renewal.status()['phase'] == 'error');
    expect(commits, 0);
    expect(held, isFalse);
    expect(renewal.status()['dataPrepared'], false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 1);
  });

  test('prepared data survives failure to restore the UI without repeating domain writes', () async {
    var commits = 0;
    final renewal = RenewalCoordinator(
      log: (_) {},
      acquire: (_) => () {},
      prepare: (_, _) async => {},
      commit: (_) => commits++,
      refresh: (_) async => {'phase': 'error'},
    );
    renewal.start('checkout');
    await eventually(() => renewal.status()['phase'] == 'error');
    expect(commits, 1);
    expect(renewal.status()['dataPrepared'], true);
    expect(renewal.status()['error'], contains('moment refresh'));
  });

  test('stopping aborts preparation and cannot promote a late recipe result', () async {
    final done = Completer<Map<String, Object?>>();
    var commits = 0, held = true, aborted = false;
    final renewal = RenewalCoordinator(
      log: (_) {},
      acquire: (_) =>
          () => held = false,
      prepare: (_, signal) {
        signal.onAbort(() => aborted = true);
        return done.future;
      },
      commit: (_) => commits++,
      refresh: (_) async => {'phase': 'ready'},
    );
    renewal.start('checkout');
    renewal.close();
    expect(aborted, isTrue);
    done.complete({});
    await eventually(() => !held);
    expect(commits, 0);
    expect(() => renewal.start('checkout'), throwing('stopping'));
  });
}
