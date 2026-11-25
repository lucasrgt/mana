import 'package:flutter/foundation.dart';

import 'currency.dart';

/// Exact integer minor-unit monetary value (zero floating-point drift).
/// Matches Ash/Postgres `integer` cent columns cleanly via [fromJson]/[toJson].
@immutable
final class ManaMoney {
  const ManaMoney({required this.minorUnits, required this.currency});

  factory ManaMoney.fromMajor(double amount, ManaCurrency currency) => ManaMoney(
    minorUnits: (amount * currency.minorUnitFactor).round(),
    currency: currency,
  );

  factory ManaMoney.fromJson(Map<String, dynamic> json) => ManaMoney(
    minorUnits: (json['minor_units'] as num).toInt(),
    currency: ManaCurrency.byCode((json['currency'] as String?) ?? 'BRL'),
  );

  final int minorUnits;
  final ManaCurrency currency;

  double get majorUnits => minorUnits / currency.minorUnitFactor;

  bool get isZero => minorUnits == 0;
  bool get isNegative => minorUnits < 0;

  String format() => currency.formatMinorWithSymbol(minorUnits);

  String formatWhole() => currency.formatWholeWithSymbol(majorUnits);

  ManaMoney operator +(ManaMoney other) {
    assert(
      other.currency == currency,
      'Cannot add ${other.currency.code} to ${currency.code}',
    );
    return ManaMoney(
      minorUnits: minorUnits + other.minorUnits,
      currency: currency,
    );
  }

  ManaMoney operator -(ManaMoney other) {
    assert(
      other.currency == currency,
      'Cannot subtract ${other.currency.code} from ${currency.code}',
    );
    return ManaMoney(
      minorUnits: minorUnits - other.minorUnits,
      currency: currency,
    );
  }

  Map<String, dynamic> toJson() => {
    'minor_units': minorUnits,
    'currency': currency.code,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManaMoney &&
          other.minorUnits == minorUnits &&
          other.currency == currency;

  @override
  int get hashCode => Object.hash(minorUnits, currency);
}
