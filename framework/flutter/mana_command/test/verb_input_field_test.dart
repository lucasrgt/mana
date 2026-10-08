import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

void main() {
  String message(String code) => 'refused:$code';

  test('a CPF input masks, checks digits and sends digits', () {
    const cpf = VerbInput(
      name: 'cpf',
      type: 'string',
      required: true,
      format: 'br-cpf',
    );
    expect(cpf.br, BrFormat.cpf);
    expect(cpf.keyboard, TextInputType.number);
    expect(cpf.formatters.single, isA<BrInputFormatter>());
    final validate = cpf.validator(message);
    expect(validate(''), 'refused:required');
    expect(validate('111.111.111-11'), 'refused:format');
    expect(validate('529.982.247-25'), isNull);
    expect(cpf.value(' 529.982.247-25 '), '52998224725');
    expect(cpf.value(''), isNull);
  });

  test('numbers and plain text follow their own rules', () {
    const copies = VerbInput(name: 'copies', type: 'integer', min: 1, max: 5);
    expect(copies.keyboard, const TextInputType.numberWithOptions());
    expect(copies.formatters.single, isA<FilteringTextInputFormatter>());
    expect(copies.validator(message)('9'), 'refused:too_large');
    expect(copies.value('3'), 3);

    const delta = VerbInput(name: 'delta', type: 'number', min: -1);
    expect(
      delta.keyboard,
      const TextInputType.numberWithOptions(signed: true, decimal: true),
    );
    expect(delta.value('0.5'), 0.5);

    const note = VerbInput(name: 'note', type: 'string', maxLength: 10);
    expect(note.keyboard, TextInputType.text);
    expect(note.formatters.single, isA<LengthLimitingTextInputFormatter>());
    expect(note.validator(message)('ok'), isNull);
    expect(note.value('  hi '), 'hi');
  });

  test(
    'a unique input asks once the typing pauses and ignores superseded text',
    () async {
      const email = VerbInput(name: 'email', type: 'string', unique: true);
      final asked = <String>[];
      final check = uniqueValidator(email, (value) async {
        asked.add(value);
        return value == 'taken@x';
      }, pause: const Duration(milliseconds: 20));
      final first = check('taken@');
      final second = check('taken@x');
      expect(await first, isNull);
      expect(await second, 'taken');
      expect(asked, ['taken@x']);
      expect(await check('  '), isNull);
      const plain = VerbInput(name: 'note', type: 'string');
      expect(await uniqueValidator(plain, (_) async => true)('x'), isNull);
    },
  );
}
