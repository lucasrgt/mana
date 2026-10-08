import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const _register = ManaVerb(
  resource: 'vehicle_registration',
  name: 'register',
  action: 'register',
  inputs: [
    VerbInput(
      name: 'plate',
      type: 'string',
      required: true,
      format: 'br-plate',
      unique: true,
    ),
    VerbInput(name: 'nickname', type: 'string', maxLength: 5),
    VerbInput(name: 'seats', type: 'integer', min: 1),
  ],
);

void main() {
  test('the declared checks run first, then unique, then the server places its refusals', () async {
    final form = VerbForm(
      _register,
      taken: (input, value) async => value == 'ABC1D23',
    );
    var sent = <String, Object?>{};

    expect(await form.submit((inputs) async => sent = inputs), isNull);
    expect(form.errorOf('plate'), 'required');

    form.text('plate').text = 'abc-1d23';
    form.text('nickname').text = 'toolong';
    expect(await form.submit((inputs) async => sent = inputs), isNull);
    expect(form.errorOf('nickname'), 'too_long');

    form.text('nickname').text = 'van';
    form.edited('nickname');
    expect(await form.submit((inputs) async => sent = inputs), isNull);
    expect(form.errorOf('plate'), 'taken');

    form.text('plate').text = 'XYZ9A87';
    form.text('seats').text = '4';
    expect(
      await form.submit<Object>(
        (inputs) async => throw StateError('refused'),
        body: (_) => {
          'errors': [
            {
              'code': 'vehicle.blocked',
              'source': {'pointer': '/data/attributes/plate'},
            },
          ],
        },
      ),
      isNull,
    );
    expect(form.errorOf('plate'), 'vehicle.blocked');

    form.set('seats', 6);
    expect(await form.submit((inputs) async => sent = inputs), isNotNull);
    expect(sent, {'plate': 'XYZ9A87', 'nickname': 'van', 'seats': 6});
  });
}
