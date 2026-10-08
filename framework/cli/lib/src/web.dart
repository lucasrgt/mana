import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'failure.dart';

/// Gives a Flutter web build release-specific entrypoints. A host whose browser
/// TTL outlives a deploy (Pages' custom domains) would otherwise mix an old
/// cached script with a new page.
({String main, String bootstrap}) versionWebAssets(String directory) {
  final main = File(p.join(directory, 'main.dart.js')).readAsBytesSync();
  final bootstrap = File(
    p.join(directory, 'flutter_bootstrap.js'),
  ).readAsStringSync();
  final index = File(p.join(directory, 'index.html')).readAsStringSync();
  if (!bootstrap.contains('"mainJsPath":"main.dart.js"') ||
      !index.contains('src="flutter_bootstrap.js"')) {
    throw const ManaFailure(
      'Unexpected Flutter web entrypoints; refusing an unversioned release.',
    );
  }
  String digest(List<int> value) =>
      sha256.convert(value).toString().substring(0, 20);
  final mainName = 'main.${digest(main)}.dart.js';
  final nextBootstrap = bootstrap.replaceAll(
    '"mainJsPath":"main.dart.js"',
    '"mainJsPath":"$mainName"',
  );
  final bootstrapName =
      'flutter_bootstrap.${digest(utf8.encode(nextBootstrap))}.js';
  // Keep the conventional files for pages opened before this release.
  File(p.join(directory, mainName)).writeAsBytesSync(main);
  File(p.join(directory, bootstrapName)).writeAsStringSync(nextBootstrap);
  File(p.join(directory, 'index.html')).writeAsStringSync(
    index.replaceFirst('src="flutter_bootstrap.js"', 'src="$bootstrapName"'),
  );
  stdout.writeln('Versioned Flutter entrypoints: $mainName, $bootstrapName');
  return (main: mainName, bootstrap: bootstrapName);
}
