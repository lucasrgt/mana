import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'paths.dart';

/// Protocol version is independent of the Ash manifest and CLI JSON versions.
const protocol = {'name': 'moments', 'version': '0.1', 'profile': 'mana-ash-flutter'};
const _specificationSha256 = '4e9ab024dcf808f814eb6ac165ead5dfa578a25689355abec128666ce80b3713';

Map<String, Object?> capabilities() {
  final actual = sha256.convert(File(p.join(momentsRoot(), 'protocol-v0.1.md')).readAsBytesSync()).toString();
  if (actual != _specificationSha256) {
    throw const MomentsError('Moments specification changed; reconcile protocol capabilities before publishing them');
  }
  return {
    'version': 1,
    'protocol': {...protocol, 'specificationSha256': _specificationSha256},
    'conformance': 'partial',
    'scope': 'Engine declarations; not evidence that a particular instance or journey passed',
    'capabilities': {
      'declaredLineage': true,
      'uiResume': true,
      'appOwnedPreparation': true,
      'linearVerifiedJourney': true,
      'linearNavigationWithoutCriteria': true,
      'declaredCheckpointComposition': true,
      'recordedPreparationRecovery': true,
      'parentMaterialization': true,
      'independentFork': true,
      'wholeSituationSnapshot': false,
      'normalizedVersionComparison': false,
      'saveExplorationAsMoment': false,
      'traceFromRoot': false,
    },
    'executionProfiles': {
      'preparation': {
        'commands': ['prepare'],
        'requires': ['project preparation adapter', 'new named profile'],
        'recovery': 'recover --preparation for registered infrastructure journals; no adapter imports or recipe replay',
        'limits':
            'Adapter owns build and provisioning. Recovery preserves declared data services and does not turn interrupted preparation into a prepared profile',
      },
      'composition': {
        'commands': ['compose'],
        'parentMaterialization': false,
        'independentFork': false,
        'requires': ['project composition adapter', 'named prepared profile', 'explicit browser host'],
        'verification':
            'Historical selected steps and checkpoints per surface; no final-state approval of every referenced Moment',
        'recovery': 'recover --session closes recorded resources without importing the adapter or replaying gestures',
        'limits':
            'Sequential composition; adapter owns preparation, leases and fault policy. No automatic branch enumeration or universal fresh build',
      },
      'launcher': {
        'commands': ['up', 'open', 'run', 'navigate', 'profile'],
        'parentMaterialization': false,
        'independentFork': false,
      },
      'materialized': {
        'commands': ['open --isolated', 'fork'],
        'parentMaterialization': true,
        'independentFork': true,
        'requires': [
          'project materialization adapter',
          'captured roots for every declared layer',
          'browser host for ash-flutter-local',
        ],
        'builtInLayers': ['postgres', 'flutter-actor', 'private-json'],
        'verification': 'Explicit check <name> --session <directory>; --actor required for ambiguous selection',
        'recovery': 'Cleanup only; no recipe replay or automatic reopening',
        'limits':
            'Supported scenarios belong to the adapter; no universal external-effect rollback, network jail or hot reload in fixed-artifact forks',
      },
    },
    'gestures': {
      'tap': {
        'step': 'step(:name, tap: "key")',
        'transport': 'flutter-pointer',
        'does':
            'Pointer down and up at the centre of the one widget with ValueKey<String>(key), through hit testing and the gesture arena; never calls onTap/onPressed directly',
        'waits':
            'Up to 6 s for a target that is loading, animating in, covered or disabled; scrolls a mounted target out of view into it once; pages through mounted scrollables to build one a lazy list has not built yet',
        'refuses':
            'not-found, ambiguous (two widgets share the key), not-visible, occluded, disabled, stale (the Moment changed)',
      },
      'fill': {
        'step': 'step(:name, fill: "key", from: "input.reference")',
        'transport': 'flutter-text-input',
        'does':
            'Focuses the one EditableText under the key with a tap, then EditableTextState.updateEditingValue with the resolved input, so formatters and onChanged run; never assigns the controller',
        'waits': 'As tap, lazy lists included',
        'refuses': 'Read-only, hidden, unfocusable or ambiguous fields; empty text or more than 4096 UTF-16 units',
        'privacy':
            'from names a reference the app resolves locally; the value never reaches the CLI, receipts or reports',
      },
      'submit': {
        'step': 'step(:name, submit: "key")',
        'transport': 'flutter-text-input',
        'does':
            "Focuses the field with a tap, then EditableTextState.performAction with the field's own textInputAction (done, next, search, send), so onSubmitted and focus traversal run as from the keyboard's action key",
      },
      'reveal': {
        'step': 'step(:name, reveal: "key")',
        'transport': 'flutter-scroll',
        'does':
            'Scrollable.ensureVisible on the target; a target a lazy list has not built is first searched for by paging the mounted scrollables, the topmost popup first, and the rest go back where they were',
      },
      'swipe': {
        'step': 'step(:name, swipe: "key", direction: :left | :right | :up | :down)',
        'transport': 'flutter-pointer',
        'does':
            "Drags the target's centre across 60% of its size in ten pointer moves over ~160 ms: page views, carousels, dismissibles and lists move as under a finger",
      },
      'long_press': {
        'step': 'step(:name, long_press: "key")',
        'transport': 'flutter-pointer',
        'does': 'Holds the pointer on the target for 600 ms (past kLongPressTimeout) before lifting',
      },
      'back': {
        'step': 'step(:name, back: true)',
        'transport': 'flutter-navigation',
        'does':
            "Sends popRoute on flutter/navigation, as the system back button: the dialog or sheet on top closes, a pushed page pops, a router's back dispatcher decides",
      },
      'inputSuffix': {
        'step': 'step(:name, tap: "flow-service-", from: "service.id")',
        'does':
            'A tap, swipe, long_press or submit with from appends the resolved value to the key, for keys built from record ids',
      },
      'postconditions': {
        'step': 'until: [:check, ...] with check(..., scope: :step)',
        'does':
            'After a gesture, waits (8 s) for the next screen reports and backend observations until every named criterion holds; a step never retries its gesture',
      },
    },
    'surfaces': {
      'routes':
          'The launch route and every route the app reaches; a destination field reports the route pattern (/partners/:id)',
      'deepLinks':
          "Query parameters on the launch route open a record directly (/traveler?point=<id>); the app owns the link",
      'dialogs': 'showDialog, confirmations and modals over the app navigator; tap their actions, back closes them',
      'bottomSheets': 'Modal and persistent sheets; their content scrolls and reveals like any scrollable',
      'popupMenus':
          'Dropdown and select menus: their options are reached even past the visible part of a lazy menu list',
      'overlayState':
          "An app projecting its navigator's open popups (an overlay field) lets steps wait for a popup to open or close",
      'scrollables': 'Nested scrollables, lazy lists, grids and slivers; paging is bounded to 200 pages per gesture',
      'pageViews': 'Page views and carousels by swipe, or by their own arrow buttons with tap',
      'textInput': 'Text fields with formatters, focus traversal and the keyboard action key',
      'disabledAndLoading': 'Disabled controls and loading screens are waited for, not tapped',
      'platformViews':
          "Not reachable: native views drawn outside Flutter (Google Maps, WebView, camera preview); give the app a Flutter stand-in in Moments builds, or a deep link to the state behind it",
    },
    'handOffs': {
      'primitive': 'MomentHandOff.open(label, launch) in live_ui',
      'does':
          "Opening something outside the app (a payment page, a chat app, the browser, the phone's maps) is recorded as a label in a running Moment instead of performed; the app projects MomentHandOff.opened as its handOff field",
      'external effects':
          'What the other app would do (a payment, a reply) is the recipe\'s to play, for instance by sending the webhook the provider would',
      'systemPickers':
          'Photo, file and contact pickers are the app\'s to replace with a Moments stand-in that returns a fixture',
    },
    'backendState': {
      'recipes':
          'Moments.RecipeSet recipes prepare the situation through the app\'s own Ash actions and return the launch: route, account, inputs, knobScope',
      'observe': 'backend_equals checks read the projection the recipe\'s observe/2 answers, read through Ash',
      'knobScopes':
          'Mana.Knobs.scoped/2 opens a scope of knob values for one run; the app sends x-mana-knob-scope with every request and observe runs inside it, so runs beside it keep the shared values. Only where config :mana_core, knob_scopes: true',
      'actionEvidence':
          'Each gesture\'s requests carry x-mana-gesture and come back with the Ash actions they ran (x-mana-actions)',
      'isolation':
          'Parallel workers share one database: recipes create their own records (and their own map spots, cities or names) instead of relying on what others left',
    },
    'limits': [
      'No OS-level input: system keyboard, IME composition, autofill, native accessibility and OS dialogs (permissions) are not exercised',
      'No pixel or visual assertions; checks compare declared projections and backend observations',
      'Gestures are never replayed: an uncertain outcome stops the journey for inspection',
      'Lazy-list search pages through what is mounted; content that loads only on a network event after scrolling is waited for within the gesture deadline',
    ],
    'semantics': {
      'open --fresh': 'Restore declared UI fields; not a whole-system reset',
      'up --fresh': 'Run app-owned preparation; not snapshot restoration',
      'reset --discard-data': 'Discard the stopped local database; not protocol reset-to-origin',
      'navigate':
          'Prepare one root or traverse a coordinator-owned actor and capture declared UI; no final business verification or whole-situation snapshot',
      'run': 'Prepare and verify one linear journey; not exploration of all branches',
      'compose':
          'Select existing steps and criteria across prepared surfaces; preserve checkpoint scope and declared ancestry',
      'prepare':
          'Run the project preparation adapter for a new profile; no implicit overwrite or production readiness claim',
      'profile':
          'Execute one root journey once and observe engine phase latency plus bounded request-context Ash/Ecto telemetry; not CPU, heap, load or parent materialization',
      'graph': 'Declared ancestry only; no materialization, traversal or verification evidence',
      'open --isolated':
          'Traverse declared ancestors and restore captured layers through the project adapter; final checks remain explicit',
      'fork':
          'Open independent copies of captured declared layers through the project adapter; does not clone arbitrary external services',
    },
  };
}

/// Never flatten a transition into an independent recipe. Kept at mutation
/// seams, not just the CLI, so alternate clients cannot bypass capability
/// negotiation.
void assertMaterializable(Map<String, Object?>? scene) {
  if (scene?['from'] != null) {
    throw const MomentsError(
      'Parent materialization requires open --isolated or fork with a supporting project adapter; the single-runtime launcher cannot flatten this Moment into a root',
    );
  }
}
