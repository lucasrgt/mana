# mana_br

Client half of `Mana.BR` (`framework/ash/br`). The server types publish
`format: br-cpf | br-cnpj | br-cep | br-phone | br-plate` in the API schema; this
package validates, masks and normalizes those fields exactly as the server does.

```dart
import 'package:mana_br/mana_br.dart';

AppInput(
  keyboardType: BrFormat.cpf.keyboard,
  inputFormatters: [BrFormat.cpf.formatter],
  validator: BrFormat.cpf.validator(message: copy.invalidCpf),
);
BR.isCnpj(value); BR.maskCep(value); BrFormat.phone.canonical(value);
```

Do not write CPF, CNPJ, CEP, phone or plate masks and check digits in an app:
`mana_lints` reports them (`mana_use_primitives`) and points here.
