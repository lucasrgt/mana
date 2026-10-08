import 'dart:async';

import 'package:flutter/widgets.dart';

import 'draft_field.dart';
import 'view_binding.dart';

/// Owns controllers and codecs for explicitly declared UI fields.
/// The app owns modal/data readiness and the identity of the record being edited.
/// Nothing here performs network actions or restores a command in progress.
final class MomentDraft {
  MomentDraft({
    required String route,
    required List<DraftField<Object?>> fields,
    required this.restoreView,
    bool Function()? focusWhen,
    this.focusKey = 'focus',
  }) : _fields = List.unmodifiable(fields),
       _focusWhen = focusWhen ?? (() => true) {
    final keys = <String>{'route', 'scrollOffset', focusKey};
    if (focusKey.isEmpty || keys.length != 3) {
      throw ArgumentError('Draft focus key collides with a reserved field');
    }
    for (final field in _fields) {
      if (field is TextDraftField && field.key == 'none') {
        throw ArgumentError('Text draft key collides with the focus sentinel');
      }
      final names = [
        field.key,
        if (field is TextDraftField) ...[field.baseKey, field.extentKey],
      ];
      for (final name in names) {
        if (name.isEmpty || !keys.add(name)) {
          throw ArgumentError('Duplicate or reserved draft key: $name');
        }
      }
    }
    binding = MomentViewBinding(
      route: route,
      scroll: scroll,
      read: snapshot,
      restore: _restore,
    );
    for (final field in _fields) {
      _values[field] = field.initial;
      if (field is TextDraftField) {
        final text = TextEditingController(), focus = FocusNode();
        _text[field] = text;
        _focus[field] = focus;
        text.addListener(capture);
        focus.addListener(() {
          // Restart/browser blur must not erase the last editing focus.
          if (focus.hasFocus) _lastFocused = field;
          capture();
        });
      }
    }
  }

  final List<DraftField<Object?>> _fields;
  final String focusKey;
  final FutureOr<void> Function() restoreView;
  final bool Function() _focusWhen;
  final _values = <DraftField<Object?>, Object?>{};
  final _text = <TextDraftField, TextEditingController>{};
  final _focus = <TextDraftField, FocusNode>{};
  final scroll = ScrollController();
  late final MomentViewBinding binding;
  TextDraftField? _lastFocused;
  bool _disposed = false;
  int _restoration = 0;

  void _require(DraftField<Object?> field) {
    if (_disposed) throw StateError('MomentDraft is disposed');
    if (!_values.containsKey(field)) {
      throw ArgumentError('Undeclared draft field: ${field.key}');
    }
  }

  T read<T>(DraftField<T> field) {
    _require(field);
    if (field case final TextDraftField textField) {
      return _text[textField]!.text as T;
    }
    return _values[field] as T;
  }

  void write<T>(DraftField<T> field, T value) {
    _require(field);
    final decoded = field.decode(value);
    if (field case final TextDraftField textField) {
      _text[textField]!.text = decoded as String;
    } else {
      _values[field] = decoded;
    }
    capture();
  }

  TextEditingController textController(TextDraftField field) {
    _require(field);
    return _text[field]!;
  }

  FocusNode focusNode(TextDraftField field) {
    _require(field);
    return _focus[field]!;
  }

  /// Reset only named fields; the app chooses when a draft's identity changes.
  void reset(Iterable<DraftField<Object?>> fields) {
    final selected = fields.toList();
    for (final field in selected) {
      _require(field);
    }
    for (final field in selected) {
      if (_lastFocused == field) _lastFocused = null;
      if (field is TextDraftField) {
        _text[field]!.clear();
      } else {
        _values[field] = field.initial;
      }
    }
    capture();
  }

  Map<String, dynamic> snapshot() => {
    for (final field in _fields) field.key: field.decode(read(field)),
    for (final entry in _text.entries) ...{
      entry.key.baseKey: entry.value.selection.baseOffset.clamp(
        0,
        entry.value.text.length,
      ),
      entry.key.extentKey: entry.value.selection.extentOffset.clamp(
        0,
        entry.value.text.length,
      ),
    },
    focusKey: _focusWhen() ? _lastFocused?.key ?? 'none' : 'none',
  };
  Future<void> _restore(Map<String, dynamic> projection) async {
    if (_disposed) return;
    // Decode everything before touching any live controller.
    final values = {
      for (final field in _fields) field: field.decode(projection[field.key]),
    };
    final editing = <TextDraftField, TextEditingValue>{};
    for (final field in _text.keys) {
      final text = values[field] as String;
      int offset(String key) {
        final value = projection[key] ?? 0; // Older drafts omitted selection.
        if (value is! num || !value.isFinite) {
          throw FormatException('Invalid draft selection: $key');
        }
        return value.toInt().clamp(0, text.length);
      }

      editing[field] = TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: offset(field.baseKey),
          extentOffset: offset(field.extentKey),
        ),
      );
    }
    final focus = projection[focusKey] ?? 'none';
    if (focus != 'none' && !_text.keys.any((field) => field.key == focus)) {
      throw FormatException('Invalid draft focus: $focusKey');
    }
    final serial = ++_restoration;
    _values.addAll(values);
    _lastFocused = null;
    for (final node in _focus.values) {
      if (node.hasFocus) node.unfocus();
    }
    for (final entry in editing.entries) {
      _text[entry.key]!.value = entry.value;
    }
    await restoreView();
    if (_disposed || serial != _restoration) return;
    for (final field in _text.keys) {
      if (field.key != focus) continue;
      _lastFocused = field;
      if (!_focusWhen()) return;
      _focus[field]!.requestFocus();
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      // Web focus may select all: reapply selection after mounting and focus.
      if (!_disposed && serial == _restoration) {
        _text[field]!.selection = editing[field]!.selection;
      }
      return;
    }
  }

  void capture() {
    if (!_disposed) binding.capture();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _restoration++;
    binding.dispose();
    for (final controller in _text.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    scroll.dispose();
  }
}
