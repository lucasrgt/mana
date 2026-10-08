import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:path/path.dart' as p;

/// A shared library (a package without `lib/main.dart`) never imports an app
/// (a package with one): what apps share flows down to them, never back up.
final class LibraryIndependence extends AnalysisRule {
  LibraryIndependence()
    : super(
        name: 'mana_library_independence',
        description: 'A shared library never imports an app.',
      );

  static const code = LintCode(
    'mana_library_independence',
    "This library imports the app '{0}'.",
    correctionMessage: 'Move what the library needs into it (or a library below it), or take it as a parameter.',
  );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final root = context.package?.root;
    if (root == null || _isApp(root)) return;
    registry.addImportDirective(this, _Visitor(this, root.provider));
  }
}

bool _isApp(Folder root) => root.getFolder('lib').getFile('main.dart').exists;

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.files);
  final LibraryIndependence rule;
  final ResourceProvider files;

  @override
  void visitImportDirective(ImportDirective node) {
    final target = node.libraryImport?.importedLibrary?.firstFragment.source.fullName;
    if (target == null) return;
    var folder = files.getFile(target).parent;
    while (!folder.getFile('pubspec.yaml').exists) {
      if (folder.isRoot) return;
      folder = folder.parent;
    }
    if (_isApp(folder)) rule.reportAtNode(node.uri, arguments: [p.basename(folder.path)]);
  }
}
