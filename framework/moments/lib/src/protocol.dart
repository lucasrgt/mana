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
