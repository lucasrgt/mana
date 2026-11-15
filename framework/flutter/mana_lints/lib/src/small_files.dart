import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Most lines a hand-written Dart file may have. A screen past it holds more
/// than one idea: its sections, dialogs and view model go to their own files
/// beside it, the way the backend keeps one resource or action per module.
const maxFileLines = 200;

/// A hand-written Dart file stays at or under [maxFileLines] lines. Generated
/// files (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, or a first line that
/// says `GENERATED CODE`) are not counted.
final class SmallFiles extends AnalysisRule {
  SmallFiles()
    : super(
        name: 'mana_small_files',
        description:
            'A hand-written Dart file stays at or under $maxFileLines lines.',
      );

  static const code = LintCode(
    'mana_small_files',
    'This file has {0} lines; the limit is {1}.',
    correctionMessage:
        'Split it by responsibility: move each section, dialog, sheet or view '
        'model into its own file in the same feature folder.',
  );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final path = context.definingUnit.file.path;
    if (_generated.any(path.endsWith)) return;
    registry.addCompilationUnit(this, _Visitor(this));
  }

  static const _generated = ['.g.dart', '.freezed.dart', '.mocks.dart'];
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);
  final SmallFiles rule;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final lines = node.lineInfo.lineCount;
    if (lines <= maxFileLines) return;
    final first = node.beginToken.precedingComments?.lexeme ?? '';
    if (first.contains('GENERATED CODE')) return;
    final anchor = node.directives.isNotEmpty
        ? node.directives.first
        : node.declarations.isNotEmpty
        ? node.declarations.first
        : null;
    if (anchor == null) return;
    rule.reportAtNode(anchor, arguments: ['$lines', '$maxFileLines']);
  }
}
