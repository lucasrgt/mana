import 'package:flutter/services.dart';

import 'currency.dart';

/// Live right-to-left cent-growth currency formatter: typing `25000` grows
/// cleanly as `0,02` -> `0,25` -> `2,50` -> `25,00` -> `250,00` -> `1.250,00`
/// (BRL) or `0.02` -> `250.00` -> `1,250.00` (USD).
final class ManaCurrencyInputFormatter extends TextInputFormatter {
  const ManaCurrencyInputFormatter(this.currency, {this.maxDigits = 12});

  final ManaCurrency currency;
  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final rawDigits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (rawDigits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    final trimmed = rawDigits.replaceFirst(RegExp(r'^0+'), '');
    if (trimmed.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    final clamped = trimmed.length > maxDigits
        ? trimmed.substring(0, maxDigits)
        : trimmed;
    final minor = int.tryParse(clamped) ?? 0;
    final formatted = currency.formatMinorUnits(minor);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
