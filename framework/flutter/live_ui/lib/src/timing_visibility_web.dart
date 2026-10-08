import 'dart:js_interop';

@JS('document.visibilityState')
external JSString get _visibility;
@JS('document.hasFocus')
external JSBoolean _hasFocus();

Map<String, Object> timingVisibility() => {
  'visibility': _visibility.toDart,
  'focused': _hasFocus().toDart,
};
