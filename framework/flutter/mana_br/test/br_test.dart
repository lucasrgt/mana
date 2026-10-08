import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_br/mana_br.dart';

void main() {
  test('CPF and CNPJ check digits match Mana.BR', () {
    expect(BR.isCpf('529.982.247-25'), isTrue);
    expect(BR.isCpf('52998224724'), isFalse);
    expect(BR.isCpf('111.111.111-11'), isFalse);
    expect(BR.isCnpj('11.222.333/0001-81'), isTrue);
    expect(BR.isCnpj('11222333000182'), isFalse);
    expect(BR.isCnpj('00000000000000'), isFalse);
  });

  test(
    'masks add separators only before a following digit and drop extra digits',
    () {
      expect(BR.maskCpf('5299'), '529.9');
      expect(BR.maskCpf('529982247259999'), '529.982.247-25');
      expect(BR.maskCnpj('11222333000181'), '11.222.333/0001-81');
      expect(BR.maskCep('01310100'), '01310-100');
      expect(BR.maskCep('013'), '013');
      expect(BR.maskPhone('1133334444'), '(11) 3333-4444');
      expect(BR.maskPhone('11987654321'), '(11) 98765-4321');
      expect(BR.maskPhone(''), '');
    },
  );

  test('phone and plate canonical forms follow the server', () {
    expect(BR.phone('+55 (11) 98765-4321'), '11987654321');
    expect(BR.phone('0198765432'), isNull);
    expect(BR.plate('abc-1d23'), 'ABC1D23');
    expect(BR.isPlate('ABC1234'), isTrue);
    expect(BR.isPlate('AB12345'), isFalse);
  });

  test('schema formats map to behaviour, messages and keyboards', () {
    expect(BrFormat.fromSchema('br-cpf'), BrFormat.cpf);
    expect(BrFormat.fromSchema('email'), isNull);
    expect(BrFormat.cpf.canonical('529.982.247-25'), '52998224725');
    expect(BrFormat.cnpj.display('11222333000181'), '11.222.333/0001-81');
    expect(BrFormat.cnpj.display('123'), '123');
    expect(BrFormat.cep.keyboard, TextInputType.number);
    expect(BrFormat.cpf.validator()('123'), 'is not a valid CPF');
    expect(BrFormat.cpf.validator(required: false)(''), isNull);
    final edited = BrFormat.cpf.formatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '52998224725'),
    );
    expect(edited.text, '529.982.247-25');
    expect(edited.selection.baseOffset, edited.text.length);
  });
}
