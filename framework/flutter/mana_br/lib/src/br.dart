/// Brazilian identifiers, mirroring `Mana.BR` on the server.
abstract final class BR {
  static String digits(String value) => value.replaceAll(RegExp(r'\D'), '');

  static bool isCpf(String value) {
    final digits = BR.digits(value);
    if (digits.length != 11 || _same(digits)) return false;
    final numbers = digits.split('').map(int.parse).toList(growable: false);
    return _check(numbers, 9, const [10, 9, 8, 7, 6, 5, 4, 3, 2]) &&
        _check(numbers, 10, const [11, 10, 9, 8, 7, 6, 5, 4, 3, 2]);
  }

  static bool isCnpj(String value) {
    final digits = BR.digits(value);
    if (digits.length != 14 || _same(digits)) return false;
    final numbers = digits.split('').map(int.parse).toList(growable: false);
    return _check(numbers, 12, const [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]) &&
        _check(numbers, 13, const [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  }

  static bool isCep(String value) => BR.digits(value).length == 8;

  /// DDD + 8 or 9 digits, without the country code; null when invalid.
  static String? phone(String value) {
    var digits = BR.digits(value);
    if ((digits.length == 12 || digits.length == 13) &&
        digits.startsWith('55')) {
      digits = digits.substring(2);
    }
    return (digits.length == 10 || digits.length == 11) &&
            !digits.startsWith('0')
        ? digits
        : null;
  }

  static bool isPhone(String value) => phone(value) != null;

  /// Uppercase alphanumerics, the stored form of a plate.
  static String plate(String value) =>
      value.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();

  /// Legacy (ABC1234) or Mercosul (ABC1D23).
  static bool isPlate(String value) {
    final plate = BR.plate(value);
    return RegExp(r'^[A-Z]{3}[0-9]{4}$').hasMatch(plate) ||
        RegExp(r'^[A-Z]{3}[0-9][A-Z][0-9]{2}$').hasMatch(plate);
  }

  /// Masks while typing: separators appear only once a digit follows them,
  /// extra digits are dropped.
  static String maskCpf(String value) =>
      _mask(digits(value), const [3, 3, 3, 2], const ['.', '.', '-']);

  static String maskCnpj(String value) =>
      _mask(digits(value), const [2, 3, 3, 4, 2], const ['.', '.', '/', '-']);

  static String maskCep(String value) =>
      _mask(digits(value), const [5, 3], const ['-']);

  static String maskPhone(String value) {
    final digits = BR.digits(value);
    if (digits.length <= 10) {
      return _mask(
        digits,
        const [2, 4, 4],
        const [') ', '-'],
        prefix: digits.isEmpty ? '' : '(',
      );
    }
    return _mask(digits, const [2, 5, 4], const [') ', '-'], prefix: '(');
  }

  static String maskPlate(String value) {
    final plate = BR.plate(value);
    return plate.length > 7 ? plate.substring(0, 7) : plate;
  }

  static bool _same(String digits) => RegExp(r'^(\d)\1+$').hasMatch(digits);

  static bool _check(List<int> numbers, int position, List<int> weights) {
    var sum = 0;
    for (var i = 0; i < weights.length; i++) {
      sum += numbers[i] * weights[i];
    }
    final remainder = sum % 11;
    return numbers[position] == (remainder < 2 ? 0 : 11 - remainder);
  }

  static String _mask(
    String digits,
    List<int> groups,
    List<String> separators, {
    String prefix = '',
  }) {
    final limit = groups.fold<int>(0, (total, group) => total + group);
    final kept = digits.length > limit ? digits.substring(0, limit) : digits;
    final out = StringBuffer(prefix);
    var offset = 0;
    for (
      var index = 0;
      index < groups.length && offset < kept.length;
      index++
    ) {
      final end = (offset + groups[index]).clamp(0, kept.length);
      out.write(kept.substring(offset, end));
      offset = end;
      if (offset < kept.length && index < separators.length) {
        out.write(separators[index]);
      }
    }
    return out.toString();
  }
}

/// The `format` a `Mana.BR` type publishes in the API schema.
enum BrFormat {
  cpf('br-cpf', 'is not a valid CPF'),
  cnpj('br-cnpj', 'is not a valid CNPJ'),
  cep('br-cep', 'must have 8 digits'),
  phone('br-phone', 'is not a valid Brazilian phone'),
  plate('br-plate', 'is not a valid Brazilian plate');

  const BrFormat(this.schema, this.message);

  /// The OpenAPI `format`, e.g. `br-cpf`.
  final String schema;

  /// The server's error message for an invalid value.
  final String message;

  static BrFormat? fromSchema(String? format) =>
      values.where((f) => f.schema == format).firstOrNull;

  bool isValid(String value) => switch (this) {
    cpf => BR.isCpf(value),
    cnpj => BR.isCnpj(value),
    cep => BR.isCep(value),
    phone => BR.isPhone(value),
    plate => BR.isPlate(value),
  };

  String mask(String value) => switch (this) {
    cpf => BR.maskCpf(value),
    cnpj => BR.maskCnpj(value),
    cep => BR.maskCep(value),
    phone => BR.maskPhone(value),
    plate => BR.maskPlate(value),
  };

  /// A stored value for reading: masked when it has the full length,
  /// unchanged otherwise. Validity is the server's concern.
  String display(String value) {
    final length = canonical(value).length;
    final complete = switch (this) {
      cpf => length == 11,
      cnpj => length == 14,
      cep => length == 8,
      phone => length == 10 || length == 11,
      plate => length == 7,
    };
    return complete ? mask(value) : value;
  }

  /// The canonical value the server stores: digits, or the normalized plate.
  String canonical(String value) => switch (this) {
    plate => BR.plate(value),
    phone => BR.phone(value) ?? BR.digits(value),
    _ => BR.digits(value),
  };
}
