import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:{{apiPackage}}/{{apiPackage}}.dart' as api;
import 'package:live_ui/live_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:result_command/result_command.dart';
import 'package:result_dart/result_dart.dart';

final class {{Record}}Item {
  const {{Record}}Item(this.id, this.title, this.changed);
  final String id;
  final String title;
  final bool changed;
}

final class {{Collection}}Api {
  {{Collection}}Api(Dio dio)
    : _api = api.{{ApiClient}}(dio: dio, interceptors: []).get{{Record}}Api();
  final api.{{Record}}Api _api;
  Future<List<{{Record}}Item>> load() async {
    final data = (await _api.list{{Collection}}()).data?.data;
    if (data == null) { throw const FormatException('Missing {{name}} data'); }
    return data.map((record) {
      final value = record.attributes;
      if (value == null) { throw const FormatException('Missing {{name}} attributes'); }
      return {{Record}}Item(record.id, value.title, value.{{stateCamel}});
    }).toList(growable: false);
  }
  Future<void> {{actionCamel}}(String id) async {
    final receipt = (await _api.{{actionCamel}}{{Record}}(
      id: id,
      {{actionCamel}}{{Record}}Request: api.{{Action}}{{Record}}Request((b) => b.data
        ..id = id
        ..type = api.{{Action}}{{Record}}RequestDataTypeEnum.{{typeCamel}}),
    )).data?.data;
    if (receipt?.id != id || receipt?.attributes?.{{stateCamel}} != true) {
      throw const FormatException('Missing action acknowledgement');
    }
  }
}

final class {{Collection}}Model {
  {{Collection}}Model(this.api);
  final {{Collection}}Api api;
  final items = signal<List<{{Record}}Item>>([]);
  final ready = signal(false);
  final failure = signal<String?>(null);
  final filter = signal('all');
  late final _command = Command1<bool, String>(_write, maxHistoryLength: 0);
  late final _execution = valueListenableToSignal(_command);
  bool get busy => _execution.value.isRunning;
  bool _disposed = false;
  int _version = 0;

  Future<bool> load() async {
    final version = ++_version;
    try {
      final result = await api.load();
      if (_disposed || version != _version) { return false; }
      items.value = result;
      ready.value = true;
      failure.value = null;
      MomentTiming.mark(MomentMark.screenReady);
      return true;
    } on Object {
      if (!_disposed && version == _version) { failure.value = 'Could not load {{name}}.'; }
      return false;
    }
  }
  AsyncResult<bool> _write(String id) async {
    try {
      await api.{{actionCamel}}(id);
      if (!await load()) { return Failure(Exception('Refresh unavailable')); }
      return const Success(true);
    } on Object {
      if (!_disposed) { failure.value = 'Could not confirm the action. Reload to inspect.'; }
      return Failure(Exception('{{Action}} unavailable'));
    }
  }
  Future<void> {{actionCamel}}(String id) async {
    if (_disposed || _command.value.isRunning || !items.peek().any((v) => v.id == id && !v.changed)) { return; }
    ++_version;
    try { await _command.execute(id); }
    finally { if (_disposed) { _command.dispose(); } }
  }
  String ids({bool changedOnly = false}) {
    final ids = items.value.where((v) => !changedOnly || v.changed).map((v) => v.id).toList()..sort();
    return ids.isEmpty ? 'none' : ids.join(',');
  }
  void dispose() {
    _disposed = true;
    _execution.dispose();items.dispose();ready.dispose();failure.dispose();filter.dispose();
    if (!_command.value.isRunning) { _command.dispose(); }
    // Dio/session belong to the application, never to this slice.
  }
}

final class {{Collection}}Screen extends StatefulWidget {
  const {{Collection}}Screen({required this.api, super.key});
  final {{Collection}}Api api;
  @override
  State<{{Collection}}Screen> createState() => _{{Collection}}ScreenState();
}
final class _{{Collection}}ScreenState extends State<{{Collection}}Screen> {
  late final model = {{Collection}}Model(widget.api);
  final scroll = ScrollController();
  late final binding = MomentViewBinding(
    route: '/{{name}}', scroll: scroll,
    read: () => {'filter': model.filter.value, 'ids': model.ids(), 'changedIds': model.ids(changedOnly: true)},
    restore: (value) { model.filter.value = value['filter'] as String; },
  );
  @override
  void initState() { super.initState();unawaited(model.load()); }
  @override
  void dispose() { binding.dispose();scroll.dispose();model.dispose();super.dispose(); }
  @override
  Widget build(BuildContext context) => SignalBuilder(builder: (context) {
    binding.attach(context, ready: model.ready.value && model.failure.value == null);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) { binding.capture(); } });
    final visible = model.items.value.where((v) => model.filter.value == 'all' || v.changed);
    return Scaffold(
      appBar: AppBar(title: const Text('{{Collection}}')),
      body: Align(alignment: Alignment.topCenter, child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(controller: scroll, padding: const EdgeInsets.all(24), children: [
          SegmentedButton<String>(segments: const [
            ButtonSegment(value: 'all', label: Text('All')),
            ButtonSegment(value: 'changed', label: Text('{{State}}')),
          ], selected: {model.filter.value}, onSelectionChanged: (values) { model.filter.value = values.single; }),
          const SizedBox(height: 24),
          if (model.failure.value case final error?) ...[
            Text(error), TextButton(onPressed: model.load, child: const Text('Reload')),
          ] else if (!model.ready.value) const Center(child: CircularProgressIndicator())
          else if (visible.isEmpty) const Text('No items')
          else for (final item in visible) Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(item.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (item.changed) const Text('{{State}}') else FilledButton(
                key: ValueKey('{{action}}-${item.id}'),
                onPressed: model.busy ? null : () => model.{{actionCamel}}(item.id),
                child: const Text('{{Action}}'),
              ),
            ]),
          )),
        ]),
      )),
    );
  });
}
