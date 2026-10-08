import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

/// A feature (`lib/features/<area>/<feature>/`) imports itself, what sits
/// directly in its area, and anything outside `lib/features`; never another
/// feature's insides. What two features share moves up to the area.
final class FeatureBoundaries extends AnalysisRule {
  FeatureBoundaries()
    : super(
        name: 'mana_feature_boundaries',
        description: "A feature never imports another feature's files.",
      );

  static const code = LintCode(
    'mana_feature_boundaries',
    "'{0}' reaches into the '{1}' feature.",
    correctionMessage: 'Move what both features need up to their area (lib/features/{2}/).',
  );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final root = context.package?.root.path;
    if (root == null) return;
    registry.addImportDirective(this, _Visitor(this, p.join(root, 'lib', 'features'), context.definingUnit.file.path));
  }
}

/// `(area, feature)` of a file under `features`, or null when it is not in one.
(String, String?)? featureOf(String features, String file) {
  if (!p.isWithin(features, file)) return null;
  final parts = p.split(p.relative(file, from: features));
  return (parts.first, parts.length > 2 ? parts[1] : null);
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.features, this.path);
  final FeatureBoundaries rule;
  final String features;
  final String path;

  @override
  void visitImportDirective(ImportDirective node) {
    final from = featureOf(features, path);
    final target = node.libraryImport?.importedLibrary?.firstFragment.source.fullName;
    if (from == null || from.$2 == null || target == null) return;
    final to = featureOf(features, target);
    if (to == null || to.$2 == null || to == from) return;
    rule.reportAtNode(node.uri, arguments: [node.uri.stringValue ?? '', '${to.$1}/${to.$2}', to.$1]);
  }
}
