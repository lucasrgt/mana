import 'package:mana/mana.dart';
import 'package:test/test.dart';

void main() {
  test('a local PostgreSQL server stands in for the sandbox', () {
    final database = labDatabase(
      null,
      environment: {'MANA_LAB_POSTGRES': 'postgres://lab:s3cret@127.0.0.1:5433'},
    );
    expect(database.url('shop_test'), 'postgres://lab:s3cret@127.0.0.1:5433/shop_test');
    expect(database.recipeToken, recipeToken({'password': 's3cret'}));
    expect(database.jwtSecret, hasLength(64));
    expect(database.webUrl, 'http://127.0.0.1:3000');
    expect(() => database.create('shop"; DROP'), throwsA(isA<ManaFailure>()));
  });

  test('a local server needs a password, and no server needs a sandbox', () {
    expect(
      () => labDatabase(null, environment: {'MANA_LAB_POSTGRES': 'postgres://lab@127.0.0.1'}),
      throwsA(isA<ManaFailure>()),
    );
    expect(() => labDatabase(null, environment: const {}), throwsA(isA<ManaFailure>()));
  });

  test('mix runs on this machine only when asked', () {
    expect(localElixir(const {}), isFalse);
    expect(localElixir({'MANA_ELIXIR': 'local'}), isTrue);
  });
}
