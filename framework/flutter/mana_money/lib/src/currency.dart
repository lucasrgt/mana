import 'package:flutter/widgets.dart';

import 'scope.dart';

/// ISO currency specification for formatting, parsing, and input masking.
@immutable
final class ManaCurrency {
  const ManaCurrency({
    required this.code,
    required this.symbol,
    required this.thousandSeparator,
    required this.decimalSeparator,
    this.decimalDigits = 2,
    this.spaceAfterSymbol = true,
  });

  final String code;
  final String symbol;
  final String thousandSeparator;
  final String decimalSeparator;
  final int decimalDigits;
  final bool spaceAfterSymbol;

  static const brl = ManaCurrency(
    code: 'BRL',
    symbol: 'R\$',
    thousandSeparator: '.',
    decimalSeparator: ',',
    spaceAfterSymbol: true,
  );

  static const usd = ManaCurrency(
    code: 'USD',
    symbol: '\$',
    thousandSeparator: ',',
    decimalSeparator: '.',
    spaceAfterSymbol: false,
  );

  static const eur = ManaCurrency(
    code: 'EUR',
    symbol: '€',
    thousandSeparator: '.',
    decimalSeparator: ',',
    spaceAfterSymbol: true,
  );

  /// Looks up a built-in currency by ISO 4217 [code] (`BRL`, `USD`, `EUR`).
  static ManaCurrency byCode(String code) => switch (code.toUpperCase()) {
    'BRL' => brl,
    'EUR' => eur,
    _ => usd,
  };

  /// Suggests a default currency for a BCP-47 language code (`pt` -> BRL, else USD).
  static ManaCurrency forLanguageCode(String languageCode) =>
      languageCode.toLowerCase().startsWith('pt') ? brl : usd;

  /// Resolves the active currency from the nearest [ManaCurrencyScope].
  static ManaCurrency of(
    BuildContext context, {
    ManaCurrency fallback = brl,
  }) => ManaCurrencyScope.of(context, fallback: fallback);

  /// Returns `10^decimalDigits` (e.g. `100` for cents).
  int get minorUnitFactor {
    var factor = 1;
    for (var i = 0; i < decimalDigits; i++) {
      factor *= 10;
    }
    return factor;
  }

  String get zeroFormatted =>
      decimalDigits > 0 ? '0$decimalSeparator${'0' * decimalDigits}' : '0';

  /// Formats an integer minor-unit amount (e.g. cents) without symbol.
  String formatMinorUnits(int minorUnits) {
    final negative = minorUnits < 0;
    final safe = minorUnits.abs();
    final sign = negative ? '-' : '';
    if (decimalDigits == 0) {
      return '$sign${_addThousands(safe.toString())}';
    }
    final factor = minorUnitFactor;
    final whole = safe ~/ factor;
    final frac = (safe % factor).toString().padLeft(decimalDigits, '0');
    return '$sign${_addThousands(whole.toString())}$decimalSeparator$frac';
  }

  /// Formats integer minor units with currency symbol (`R$ 1.250,00`, `$1,250.00`).
  String formatMinorWithSymbol(int minorUnits) {
    final negative = minorUnits < 0;
    final formatted = formatMinorUnits(minorUnits.abs());
    final sign = negative ? '-' : '';
    return spaceAfterSymbol
        ? '$sign$symbol $formatted'
        : '$sign$symbol$formatted';
  }

  /// Formats a double value with symbol (e.g. `R$ 1.250,00` or `$1,250.00`).
  String formatWithSymbol(double amount) {
    final minor = (amount * minorUnitFactor).round();
    return formatMinorWithSymbol(minor);
  }

  /// Formats a rounded whole-unit figure with symbol (`R$ 8.420`, `$2,105`).
  String formatWholeWithSymbol(double amount) {
    final whole = amount.round().abs();
    final grouped = _addThousands(whole.toString());
    final sign = amount < 0 ? '-' : '';
    return spaceAfterSymbol
        ? '$sign$symbol $grouped'
        : '$sign$symbol$grouped';
  }

  /// Parses formatted text back into integer minor units (e.g. cents).
  int parseMinorUnits(String text) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 0;
    final clamped = digits.length > 12 ? digits.substring(0, 12) : digits;
    return int.tryParse(clamped) ?? 0;
  }

  /// Parses formatted text back into a major-unit double (e.g. `250.00`).
  double parseDouble(String text) {
    final minor = parseMinorUnits(text);
    if (decimalDigits == 0) return minor.toDouble();
    return minor / minorUnitFactor;
  }

  String _addThousands(String intPart) {
    if (intPart.length <= 3) return intPart;
    final buffer = StringBuffer();
    final rem = intPart.length % 3;
    if (rem > 0) {
      buffer.write(intPart.substring(0, rem));
      if (intPart.length > rem) buffer.write(thousandSeparator);
    }
    for (var i = rem; i < intPart.length; i += 3) {
      buffer.write(intPart.substring(i, i + 3));
      if (i + 3 < intPart.length) buffer.write(thousandSeparator);
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManaCurrency && other.code == code;

  @override
  int get hashCode => code.hashCode;
}
