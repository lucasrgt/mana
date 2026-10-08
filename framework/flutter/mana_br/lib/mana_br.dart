/// Client half of `Mana.BR`: the same identifiers the Ash types accept, with
/// the same canonical form, check digits and messages. A field whose schema
/// carries `format: br-cpf` (or `br-cnpj`, `br-cep`, `br-phone`, `br-plate`)
/// uses [BrFormat] instead of a hand-written mask or validator.
library;

export 'src/br.dart';
export 'src/formatter.dart';
