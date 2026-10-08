import 'package:flutter/widgets.dart';
import 'package:mana_br/mana_br.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// The form of one verb, built from its declared inputs: a text controller
/// per input, the checks the server makes run first on the device, a
/// `unique` input asked early through [taken], and on submit the server's
/// own refusals (`verbFieldErrors`) placed on the inputs they name.
final class VerbForm extends ChangeNotifier {
  VerbForm(
    this.verb, {
    Map<String, Object?> initial = const {},
    this.taken,
    this.formats = const {},
  }) {
    for (final input in verb.inputs) {
      _text[input.name] = TextEditingController(
        text: initial[input.name] == null ? '' : '${initial[input.name]}',
      );
    }
  }

  final ManaVerb verb;

  /// Whether a `unique` input's value is already used.
  final Future<bool> Function(VerbInput input, String value)? taken;

  /// Checks for declared formats (`br-cpf` → `BR.cpf.isValid`).
  final Map<String, bool Function(String)> formats;

  final _text = <String, TextEditingController>{};
  final _chosen = <String, Object?>{};
  final _errors = <String, String>{};
  bool _sending = false;

  bool get sending => _sending;

  VerbInput input(String name) =>
      verb.inputs.firstWhere((input) => input.name == name);

  TextEditingController text(String name) =>
      _text[name] ?? (throw ArgumentError('$verb has no input $name'));

  /// The refusal code on [name] (`required`, `too_long`, `taken`, or the
  /// server's), until it is edited.
  String? errorOf(String name) => _errors[name];

  Map<String, String> get errors => Map.unmodifiable(_errors);

  /// What to send: each input's canonical value, empty ones left out.
  Map<String, Object?> get values => {
    for (final input in verb.inputs)
      if (_value(input) case final value?) input.name: value,
  };

  /// Sets an input that is not typed (a choice, a switch, a list).
  void set(String name, Object? value) {
    input(name);
    _chosen[name] = value;
    _errors.remove(name);
    notifyListeners();
  }

  Object? _value(VerbInput input) {
    if (_chosen.containsKey(input.name)) return _chosen[input.name];
    final text = _text[input.name]!.text.trim();
    if (text.isEmpty) return null;
    if (BrFormat.fromSchema(input.format) case final br?) {
      return br.canonical(text);
    }
    return switch (input.type) {
      'integer' => int.tryParse(text) ?? text,
      'number' => num.tryParse(text) ?? text,
      'boolean' => text == 'true',
      _ => text,
    };
  }

  /// Shows refusals that came back from a call made elsewhere (a view
  /// model's), each on the input it names.
  void place(Map<String, String> refusals) {
    _errors.addAll(refusals);
    notifyListeners();
  }

  /// Clears [name]'s refusal once the person edits it.
  void edited(String name) {
    if (_errors.remove(name) != null) notifyListeners();
  }

  /// Runs the declared checks; true when every input passes.
  bool validate() {
    _errors
      ..clear()
      ..addAll({
        for (final input in verb.inputs)
          if (input.check(values[input.name], formats: _formats)
              case final code?)
            input.name: code,
      });
    notifyListeners();
    return _errors.isEmpty;
  }

  Map<String, bool Function(String)> get _formats => {
    for (final format in BrFormat.values) format.schema: format.isValid,
    ...formats,
  };

  /// Validates, asks about `unique` inputs, then [run]s with [values]; a
  /// refusal the server places on inputs lands on them and answers null.
  Future<T?> submit<T>(
    Future<T> Function(Map<String, Object?> inputs) run, {
    Object? Function(Object error)? body,
  }) async {
    if (_sending || !validate()) return null;
    _sending = true;
    notifyListeners();
    try {
      if (taken case final taken?) {
        for (final input in verb.inputs.where((input) => input.unique)) {
          final value = values[input.name];
          if (value != null && await taken(input, '$value')) {
            _errors[input.name] = 'taken';
          }
        }
        if (_errors.isNotEmpty) return null;
      }
      return await run(values);
    } on Object catch (error) {
      final placed = verbFieldErrors(body?.call(error));
      if (placed.isEmpty) rethrow;
      _errors.addAll(placed);
      return null;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
