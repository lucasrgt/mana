import 'package:__name___api/__name___api.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:live_ui/live_ui.dart';

const _declaredApi = String.fromEnvironment(
  'APP_API_URL',
  defaultValue: 'http://127.0.0.1:4000',
);

/// The app as it starts: inside a Moment it opens on the list the Moment
/// prepared, otherwise on the device's own list.
Future<Widget> startApp() async {
  await MomentRuntime.initialize();
  final api = MomentRuntime.apiUrl(_declaredApi);
  String? list;
  final route = await prepareMomentLaunch(
    apiUrl: api,
    onLaunch: (launch) async => list = launch['fixture'] as String?,
  );
  return NotesApp(
    notes: __Name__Api(dio: Dio(BaseOptions(baseUrl: api))).getNoteApi(),
    list: list ?? 'my-list',
    moment: route != null,
  );
}

final class NotesApp extends StatelessWidget {
  const NotesApp({
    required this.notes,
    required this.list,
    this.moment = false,
    super.key,
  });

  final NoteApi notes;
  final String list;

  /// Started by the Moments engine, which drives and reads the screen.
  final bool moment;

  @override
  Widget build(BuildContext context) {
    final screen = NotesScreen(notes: notes, list: list, moment: moment);
    return MaterialApp(
      title: '__name__',
      home: moment ? MomentHost(navigate: (_) {}, child: screen) : screen,
    );
  }
}

final class NotesScreen extends StatefulWidget {
  const NotesScreen({
    required this.notes,
    required this.list,
    this.moment = false,
    super.key,
  });

  final NoteApi notes;
  final String list;
  final bool moment;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

final class _NotesScreenState extends State<NotesScreen> {
  final _title = TextEditingController();
  final _scroll = ScrollController();
  List<Note>? _items;

  late final _moment = widget.moment
      ? MomentViewBinding(
          route: '/',
          scroll: _scroll,
          read: () => {'notes': _items?.length ?? 0, 'fixture': widget.list},
          restore: (_) {},
        )
      : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final response = await widget.notes.listNotes(list: widget.list);
    if (mounted) setState(() => _items = response.data?.data?.toList() ?? []);
  }

  Future<void> _add() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    await widget.notes.addNote(
      addNoteRequest: AddNoteRequest(
        (b) => b.data
          ..type = AddNoteRequestDataTypeEnum.note
          ..attributes.list = widget.list
          ..attributes.title = title,
      ),
    );
    _title.clear();
    await _load();
  }

  Future<void> _complete(Note note) async {
    await widget.notes.completeNote(id: note.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    _moment?.attach(context, ready: items != null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && items != null) _moment?.capture();
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('note-title'),
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'New note'),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const ValueKey('note-add'),
                  onPressed: _add,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: _scroll,
                    children: [
                      for (final note in items)
                        CheckboxListTile(
                          key: ValueKey('note-${note.id}'),
                          title: Text(note.attributes?.title ?? ''),
                          value: note.attributes?.done ?? false,
                          // Offered by the server (Mana verbs), not decided here.
                          onChanged:
                              NoteVerbs.complete.offeredBy(
                                note.attributes?.verbs,
                              )
                              ? (_) => _complete(note)
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _moment?.dispose();
    _title.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
