import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_money/mana_money.dart';

void main() {
  test('formats BRL, USD, and EUR minor units and whole amounts cleanly', () {
    expect(ManaCurrency.brl.formatWithSymbol(1250.5), 'R\$ 1.250,50');
    expect(ManaCurrency.usd.formatWithSymbol(1250.5), '\$1,250.50');
    expect(ManaCurrency.eur.formatWithSymbol(1250.5), '€ 1.250,50');
    expect(ManaCurrency.brl.formatWholeWithSymbol(8420), 'R\$ 8.420');
    expect(ManaCurrency.usd.formatWholeWithSymbol(2105), '\$2,105');
  });

  test('ManaMoney keeps exact integer cent arithmetic and JSON round-trip', () {
    const a = ManaMoney(minorUnits: 1990, currency: ManaCurrency.brl);
    const b = ManaMoney(minorUnits: 2010, currency: ManaCurrency.brl);
    final sum = a + b;
    expect(sum.minorUnits, 4000);
    expect(sum.format(), 'R\$ 40,00');

    final parsed = ManaMoney.fromJson(sum.toJson());
    expect(parsed, sum);
  });

  test('ManaCurrencyInputFormatter grows right-to-left from cents', () {
    const fmt = ManaCurrencyInputFormatter(ManaCurrency.brl);
    final v1 = fmt.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '25000'),
    );
    expect(v1.text, '250,00');
    expect(ManaCurrency.brl.parseDouble(v1.text), 250.0);
  });

  testWidgets('ManaCurrencyScope provides currency down the tree', (
    tester,
  ) async {
    late ManaCurrency resolved;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ManaCurrencyScope(
          currency: ManaCurrency.eur,
          child: Builder(
            builder: (ctx) {
              resolved = ManaCurrencyScope.of(ctx);
              return Text(resolved.code);
            },
          ),
        ),
      ),
    );
    expect(resolved, ManaCurrency.eur);
    expect(find.text('EUR'), findsOneWidget);
  });
}
