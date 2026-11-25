# mana_br

Client half of `Mana.BR` (`framework/ash/br`). The server types publish
`format: br-cpf | br-cnpj | br-cep | br-phone | br-plate` in the API schema; this
package validates, masks and normalizes those fields exactly as the server does.
A CNPJ is numeric or alphanumeric (`12.ABC.345/01DE-35`, stored `12ABC34501DE35`),
so its field opens a text keyboard in capitals.

```dart
import 'package:mana_br/mana_br.dart';

AppInput(
  keyboardType: BrFormat.cpf.keyboard,
  textCapitalization: BrFormat.cpf.capitalization,
  inputFormatters: [BrFormat.cpf.formatter],
  validator: BrFormat.cpf.validator(message: copy.invalidCpf),
);
BR.isCnpj(value); BR.maskCep(value); BrFormat.phone.canonical(value);
```

Do not write CPF, CNPJ, CEP, phone or plate masks and check digits in an app:
`mana_lints` reports them (`mana_use_primitives`) and points here.
