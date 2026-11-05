/// The Flutter adapter of Mana: for each catalog capability whose client half
/// the Flutter side covers, the Dart files that implement it (paths relative to
/// `framework/`). The catalog's Flutter column (`adapters.flutter` in
/// `framework/catalog.toml`) is held to this map by `test/capabilities_test.dart`,
/// as mana_web's `ManaWeb.implements/0` holds the LiveView column.
///
/// Every path lives under `flutter/` (the runtime packages) or `cli/lib/` (the
/// writers that generate an app's client from its contract).
const flutterImplements = <String, List<String>>{
  'contracts': ['cli/lib/src/client.dart', 'cli/lib/src/contracts.dart'],
  'validation': [
    'flutter/mana_primitives/lib/mana_primitives.dart',
    'flutter/mana_command/lib/src/verb_form.dart',
  ],
  'mana-br': [
    'flutter/mana_br/lib/src/br.dart',
    'flutter/mana_br/lib/src/formatter.dart',
  ],
  // ErrorCode comes in the generated client; verbFieldErrors puts a refusal on
  // the field it names.
  'errors': [
    'cli/lib/src/client.dart',
    'flutter/mana_primitives/lib/mana_primitives.dart',
  ],
  'uploads': ['flutter/mana_command/lib/src/attachments.dart'],
  // The filter runs on the server; the client half is the read's argument in
  // the generated client.
  'search': ['cli/lib/src/client.dart'],
  'enums-shapes': ['cli/lib/src/client.dart'],
  'session': [
    'flutter/ash_session/lib/ash_session.dart',
    'flutter/ash_session/lib/password_recovery.dart',
    'flutter/ash_session/lib/email_confirmation.dart',
  ],
  'commands': ['flutter/mana_command/lib/mana_command.dart'],
  'pagination': ['flutter/mana_command/lib/src/offset_page.dart'],
  'entities': [
    'flutter/mana_live/lib/mana_live.dart',
    'flutter/mana_primitives/lib/mana_primitives.dart',
  ],
  'verbs': [
    'cli/lib/src/primitives.dart',
    'flutter/mana_primitives/lib/mana_primitives.dart',
    'flutter/mana_command/lib/src/verb_runner.dart',
  ],
  'views': [
    'cli/lib/src/primitives.dart',
    'flutter/mana_primitives/lib/mana_primitives.dart',
  ],
  'primitives': [
    'cli/lib/src/primitives.dart',
    'flutter/mana_primitives/lib/mana_primitives.dart',
  ],
  'recovery': ['flutter/mana_command/lib/src/verb_runner.dart'],
  'flows': ['flutter/mana_command/lib/src/flow_builder.dart'],
  'notifications': ['flutter/mana_command/lib/src/notifications.dart'],
  // Labelling happens on the server; every request of the generated client
  // reaches Mana.Feature.Plug.
  'feature-health': ['cli/lib/src/client.dart'],
  'new-project': ['cli/lib/src/new_project.dart'],
  'undo': ['flutter/mana_command/lib/src/history_view.dart'],
  'moments': [
    'flutter/live_ui/lib/src/moments.dart',
    'flutter/live_ui/lib/src/moment_gestures.dart',
  ],
};
