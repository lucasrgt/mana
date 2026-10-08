import 'package:flutter/services.dart';

import 'br.dart';

/// Masks a text field as the user types, keeping the cursor at the end.
final class BrInputFormatter extends TextInputFormatter {
  BrInputFormatter(this.format);

  final BrFormat format;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final masked = format.mask(newValue.text);
    return TextEditingValue(
      text: masked,
      selection: TextSelection.collapsed(offset: masked.length),
    );
  }
}

extension BrFormatInput on BrFormat {
  /// The keyboard the field should open.
  TextInputType get keyboard => switch (this) {
    BrFormat.plate => TextInputType.text,
    BrFormat.phone => TextInputType.phone,
    _ => TextInputType.number,
  };

  TextInputFormatter get formatter => BrInputFormatter(this);

  /// A form validator returning [message] (or the server's) when invalid.
  String? Function(String?) validator({
    String? message,
    bool required = true,
  }) => (value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return required ? (message ?? this.message) : null;
    return isValid(text) ? null : (message ?? this.message);
  };
}
