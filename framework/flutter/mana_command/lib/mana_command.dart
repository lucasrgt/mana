import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mana_br/mana_br.dart';
import 'package:mana_primitives/mana_primitives.dart';
import 'package:result_command/result_command.dart';

export 'package:mana_br/mana_br.dart';
export 'package:mana_primitives/mana_primitives.dart';
export 'package:result_command/result_command.dart';

export 'src/verb_runner.dart';

export 'package:result_dart/result_dart.dart';

/// A refusal a screen renders, carrying the reason the view model decided.
/// Commands fail with exceptions; this keeps the screen's reasons typed.
final class Refusal<R extends Object> implements Exception {
  const Refusal(this.reason);
  final R reason;
  @override
  String toString() => 'Refusal($reason)';
}

/// Rebuilds for each state of [command]. [idle] also renders a cancelled run.
final class CommandBuilder<T extends Object> extends StatelessWidget {
  const CommandBuilder({
    required this.command,
    required this.idle,
    required this.running,
    required this.failure,
    required this.success,
    this.listenable,
    super.key,
  });

  final Command<T> command;

  /// Other state the screen reads (e.g. field errors on the view model).
  final Listenable? listenable;
  final WidgetBuilder idle;
  final WidgetBuilder running;
  final Widget Function(BuildContext context, Object reason) failure;
  final Widget Function(BuildContext context, T value) success;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: listenable == null
        ? command
        : Listenable.merge([command, listenable]),
    builder: (context, _) => switch (command.value) {
      RunningCommand() => running(context),
      FailureCommand(:final error) => failure(
        context,
        error is Refusal ? error.reason : error,
      ),
      SuccessCommand(:final value) => success(context, value),
      _ => idle(context),
    },
  );
}

/// A read whose latest request wins: a slower earlier answer never replaces a
/// newer one, as filters, periods and searches need. It reports the same
/// states as a command, and keeps the [last] answer while it asks again.
final class Query<T extends Object> extends ChangeNotifier
    implements ValueListenable<CommandState<T>> {
  Query(this._read);

  final Future<T> Function() _read;
  CommandState<T> _value = IdleCommand<T>();
  T? _last;
  int _run = 0;

  @override
  CommandState<T> get value => _value;

  /// The latest successful answer, also while a newer one is on its way.
  T? get last => _last;

  /// Asks again; [fresh] drops the last answer first, so the screen shows
  /// it loading instead of the stale one.
  Future<void> run({bool fresh = false}) async {
    if (fresh) _last = null;
    final run = ++_run;
    _set(RunningCommand<T>());
    try {
      final answer = await _read();
      if (run != _run) return;
      _last = answer;
      _set(SuccessCommand<T>(answer));
    } on Exception catch (error) {
      if (run == _run) _set(FailureCommand<T>(error));
    }
  }

  /// Forgets the answer; a request still on its way is ignored.
  void reset() {
    _run++;
    _last = null;
    _set(IdleCommand<T>());
  }

  /// An answer that arrives after the screen went away is dropped.
  @override
  void dispose() {
    _disposed = true;
    _run++;
    super.dispose();
  }

  bool _disposed = false;

  void _set(CommandState<T> next) {
    if (_disposed) return;
    _value = next;
    notifyListeners();
  }
}

/// Rebuilds for each state of [query]. While it asks again the [Query.last]
/// answer stays on screen; [Query.reset] first to show [loading] instead.
/// An answer [isEmpty] accepts renders [empty].
final class QueryBuilder<T extends Object> extends StatelessWidget {
  const QueryBuilder({
    required this.query,
    required this.loading,
    required this.failure,
    required this.ready,
    this.empty,
    this.isEmpty,
    super.key,
  });

  final Query<T> query;
  final WidgetBuilder loading;
  final Widget Function(
    BuildContext context,
    Object error,
    Future<void> Function() retry,
  )
  failure;
  final Widget Function(BuildContext context, T value) ready;
  final WidgetBuilder? empty;
  final bool Function(T value)? isEmpty;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: query,
    builder: (context, _) {
      Widget answer(T value) => empty != null && (isEmpty?.call(value) ?? false)
          ? empty!(context)
          : ready(context, value);
      return switch (query.value) {
        FailureCommand(:final error) => failure(context, error, query.run),
        SuccessCommand(:final value) => answer(value),
        _ => switch (query.last) {
          final last? => answer(last),
          null => loading(context),
        },
      };
    },
  );
}

/// One action at a time over a list's rows: which row is [busy], and the
/// list read again once an action lands.
final class RowAction extends ChangeNotifier {
  RowAction({required this.reload});

  final Future<void> Function() reload;
  String? busy;

  /// False when another row is busy or [action] failed.
  Future<bool> run(String id, Future<void> Function() action) async {
    if (busy != null) return false;
    _set(id);
    try {
      await action();
    } on Exception catch (error) {
      debugPrint('row action on $id failed: $error');
      _set(null);
      return false;
    }
    _set(null);
    await reload();
    return true;
  }

  /// Marks [id] busy while [read] runs, without reading the list again; null
  /// when another row is busy or [read] failed.
  Future<T?> hold<T>(String id, Future<T> Function() read) async {
    if (busy != null) return null;
    _set(id);
    try {
      return await read();
    } on Exception catch (error) {
      debugPrint('row read on $id failed: $error');
      return null;
    } finally {
      _set(null);
    }
  }

  bool _disposed = false;

  void _set(String? id) {
    if (_disposed) return;
    busy = id;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// For a view model whose answers may land after it was let go (sign-out
/// clears [ViewModels] while a load is in flight): it stays quiet instead of
/// notifying a disposed listener list.
mixin QuietAfterDispose on ChangeNotifier {
  bool _gone = false;

  bool get disposed => _gone;

  @override
  void notifyListeners() {
    if (!_gone) super.notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

/// The view models an app keeps across its screens: each made on first use
/// (one per type, or per [key]) and disposed together, on sign-out or with
/// the app.
final class ViewModels {
  final _made = <Object, ChangeNotifier>{};

  T of<T extends ChangeNotifier>(T Function() make, {Object? key}) =>
      (_made[key ?? T] ??= make()) as T;

  /// The kept one if [keep] accepts it, else a new one in its place.
  T replace<T extends ChangeNotifier>(
    T Function() make, {
    required bool Function(T current) keep,
    Object? key,
  }) {
    final current = _made[key ?? T];
    if (current is T && keep(current)) return current;
    current?.dispose();
    final made = make();
    _made[key ?? T] = made;
    return made;
  }

  T? peek<T extends ChangeNotifier>({Object? key}) => _made[key ?? T] as T?;

  /// Forgets one; the next [of] makes it again.
  void drop<T extends ChangeNotifier>({Object? key}) =>
      _made.remove(key ?? T)?.dispose();

  /// Forgets one without disposing it: the caller disposes it once its
  /// screen is gone.
  T? take<T extends ChangeNotifier>({Object? key}) =>
      _made.remove(key ?? T) as T?;

  void clear() {
    for (final model in _made.values) {
      model.dispose();
    }
    _made.clear();
  }
}

/// Performs a [ManaVerb] the way its declaration asks: shown only while the
/// record offers it ([offered], the record's `verbs`), confirmed first when its
/// declaration asks (money, cannot be undone, or `confirm: true`), and followed by Undo when it declares an
/// inverse. [builder] draws the control with the design system; a null
/// `onPressed` means the verb is not offered now. A verb that takes inputs
/// gathers them first with [collect] (null cancels), checks them against the
/// verb's rules, and hands them to [runWith]; that form is the confirmation
/// when no [confirm] is given.
final class VerbGate extends StatefulWidget {
  const VerbGate({
    required this.verb,
    required this.offered,
    required this.builder,
    this.run,
    this.collect,
    this.runWith,
    this.confirm,
    this.undo,
    this.showUndo,
    this.hideWhenNotOffered = true,
    super.key,
  });

  final ManaVerb verb;
  final Iterable<String>? offered;
  final Future<void> Function()? run;

  /// Asks for the verb's inputs, keyed by input name; null when dismissed.
  final Future<Map<String, Object?>?> Function(
    BuildContext context,
    ManaVerb verb,
  )?
  collect;

  /// Performs the verb with what [collect] gathered.
  final Future<void> Function(Map<String, Object?> inputs)? runWith;
  final Widget Function(BuildContext context, VoidCallback? onPressed) builder;

  /// Asked before a risky verb runs; required when [ManaVerb.risk] confirms.
  final Future<bool> Function(BuildContext context, ManaVerb verb)? confirm;

  /// Performs the inverse verb.
  final Future<void> Function()? undo;

  /// Offers [undo] after the verb ran, e.g. as a toast action.
  final void Function(
    BuildContext context,
    ManaVerb verb,
    Future<void> Function() undo,
  )?
  showUndo;
  final bool hideWhenNotOffered;

  @override
  State<VerbGate> createState() => _VerbGateState();
}

final class _VerbGateState extends State<VerbGate> {
  // A second activation while the verb runs does nothing: one tap, one effect.
  var _running = false;

  Future<void> _perform(BuildContext context) async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await _guarded(context);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _guarded(BuildContext context) => runVerb(
    context,
    widget.verb,
    offered: widget.offered,
    run: widget.run,
    collect: widget.collect,
    runWith: widget.runWith,
    confirm: widget.confirm,
    undo: widget.undo,
    showUndo: widget.showUndo,
  );

  @override
  Widget build(BuildContext context) {
    final available = widget.verb.offeredBy(widget.offered);
    if (!available && widget.hideWhenNotOffered) return const SizedBox.shrink();
    return widget.builder(
      context,
      available && !_running ? () => _perform(context) : null,
    );
  }
}

/// What the signed-in person may start now with no record of its own —
/// collection verbs without `from` (`Mana.Verbs.available/2`), as
/// `type.verb`. [load] asks the server; call [refresh] when what the person
/// may do could have changed (signed in, finished onboarding, created
/// something).
final class AvailableVerbs extends ChangeNotifier {
  AvailableVerbs(this._load);

  final Future<List<String>> Function() _load;
  Set<String> _names = const {};
  bool _loaded = false;

  bool get loaded => _loaded;

  /// Whether [verb] may be started now. Before the first answer it may (the
  /// server holds the real gate), so nothing hides while the offer loads.
  bool offers(ManaVerb verb) => !_loaded || verb.offeredBy(_names);

  Iterable<String> get names => _names;

  Future<void> refresh() async {
    try {
      _names = (await _load()).toSet();
      _loaded = true;
    } on Object {
      // The last answer stands until the server answers again.
      return;
    }
    notifyListeners();
  }
}

/// [VerbGate]'s rules for controls that are not widgets of their own (an
/// action bar item, a menu entry, a dialog a view model drives): nothing
/// when [offered] lacks the verb; [collect] gathers and checks the inputs
/// (null cancels, and the form stands for the confirmation); [confirm] is
/// asked when the declaration wants it; then [run] or [runWith], and Undo
/// when the verb has an inverse. True when the verb ran.
Future<bool> runVerb(
  BuildContext context,
  ManaVerb verb, {
  required Iterable<String>? offered,
  Future<void> Function()? run,
  Future<Map<String, Object?>?> Function(BuildContext context, ManaVerb verb)?
  collect,
  Future<void> Function(Map<String, Object?> inputs)? runWith,
  Future<bool> Function(BuildContext context, ManaVerb verb)? confirm,
  Future<void> Function()? undo,
  void Function(
    BuildContext context,
    ManaVerb verb,
    Future<void> Function() undo,
  )?
  showUndo,
}) async {
  if (!verb.offeredBy(offered)) return false;
  Map<String, Object?>? inputs;
  if (collect != null) {
    inputs = await collect(context, verb);
    if (inputs == null || !context.mounted) return false;
    final refused = verbInputRefusals(verb, inputs);
    if (refused.isNotEmpty) {
      throw ArgumentError('$verb inputs refused: $refused');
    }
  } else if (verb.inputs.any((input) => input.required)) {
    throw StateError('$verb takes required inputs; it needs collect');
  }
  if (verb.confirms && (confirm != null || collect == null)) {
    if (confirm == null) {
      throw StateError('$verb asks before running; it needs confirm');
    }
    if (!await confirm(context, verb) || !context.mounted) return false;
  }
  if (inputs != null) {
    await runWith!(inputs);
  } else {
    await run!();
  }
  if (verb.inverse != null &&
      undo != null &&
      showUndo != null &&
      context.mounted) {
    showUndo(context, verb, undo);
  }
  return true;
}

/// The inputs of [verb] that [values] would get refused on, with the code
/// [VerbInput.check] names (`required`, `too_long`, ...).
Map<String, String> verbInputRefusals(
  ManaVerb verb,
  Map<String, Object?> values,
) => {
  for (final input in verb.inputs)
    if (input.check(values[input.name], formats: _brFormats) case final code?)
      input.name: code,
};

/// A text field for a verb input, bound to the rules the server enforces:
/// `TextFormField(validator: input.validator(message), keyboardType:
/// input.keyboard, inputFormatters: input.formatters)`. A `Mana.BR` format
/// brings its mask, keyboard and check digits; [value] gives the server the
/// canonical form.
extension VerbInputField on VerbInput {
  /// The Brazilian format of this input, if any.
  BrFormat? get br => BrFormat.fromSchema(format);

  /// Validates typed text with [message] for each refusal code
  /// (`required`, `too_short`, `format`, ... as [VerbInput.check] names them).
  FormFieldValidator<String> validator(String Function(String code) message) =>
      (text) {
        final code = check(
          text == null || text.trim().isEmpty ? null : text.trim(),
          formats: _brFormats,
        );
        return code == null ? null : message(code);
      };

  TextInputType get keyboard =>
      br?.keyboard ??
      switch (type) {
        'integer' => TextInputType.numberWithOptions(signed: (min ?? 0) < 0),
        'number' => TextInputType.numberWithOptions(
          signed: (min ?? 0) < 0,
          decimal: true,
        ),
        _ => TextInputType.text,
      };

  List<TextInputFormatter> get formatters => [
    if (br case final format?) format.formatter,
    if (type == 'integer') FilteringTextInputFormatter.allow(RegExp(r'[-0-9]')),
    if (type == 'string' && maxLength != null && br == null)
      LengthLimitingTextInputFormatter(maxLength),
  ];

  /// What to send for typed [text]: the canonical form of a `Mana.BR` value,
  /// a number for numeric inputs, trimmed text otherwise, null when empty.
  Object? value(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (br case final format?) return format.canonical(trimmed);
    return switch (type) {
      'integer' => int.tryParse(trimmed) ?? trimmed,
      'number' => num.tryParse(trimmed) ?? trimmed,
      _ => trimmed,
    };
  }
}

/// Asks [taken] whether a `unique` input's value is already used, at most
/// once per [pause] of typing, and answers the code `taken` (or null) —
/// for `AsyncFormField`-style checks before submitting; the server's
/// refusal still lands on the field through `verbFieldErrors`.
Future<String?> Function(String text) uniqueValidator(
  VerbInput input,
  Future<bool> Function(String value) taken, {
  Duration pause = const Duration(milliseconds: 400),
}) {
  var generation = 0;
  return (text) async {
    if (!input.unique || text.trim().isEmpty) return null;
    final mine = ++generation;
    await Future<void>.delayed(pause);
    if (mine != generation) return null;
    final value = input.value(text);
    return value != null && await taken('$value') ? 'taken' : null;
  };
}

final _brFormats = {
  for (final format in BrFormat.values) format.schema: format.isValid,
};

/// A record's history (`Mana.History`), newest first, one [entry] per
/// change. Failed attempts are left out unless [showFailed].
final class HistoryTimeline extends StatelessWidget {
  const HistoryTimeline({
    required this.entries,
    required this.entry,
    this.empty = const SizedBox.shrink(),
    this.showFailed = false,
    super.key,
  });

  final List<ManaHistoryEntry> entries;
  final Widget Function(BuildContext context, ManaHistoryEntry entry) entry;
  final Widget empty;
  final bool showFailed;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final e in entries)
        if (showFailed || !e.failed) e,
    ];
    if (shown.isEmpty) return empty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final e in shown) entry(context, e)],
    );
  }
}
