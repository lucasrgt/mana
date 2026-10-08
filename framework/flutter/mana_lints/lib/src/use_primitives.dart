import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Something an app keeps writing by hand that a Mana primitive already does.
/// The same table feeds `mana capabilities` (the catalog agents read) so the
/// lint and the catalog name the same replacement.
final class Idiom {
  const Idiom({required this.what, required this.use, required this.names, this.patterns = const []});

  /// What the app reimplements, as the diagnostic says it.
  final String what;

  /// The primitive to use instead, with its import or entry point.
  final String use;

  /// Declarations whose names reveal the reimplementation.
  final RegExp names;

  /// Regular-expression sources that reveal it inside `RegExp(...)`.
  final List<RegExp> patterns;
}

final idioms = [
  Idiom(
    what: 'a Brazilian identifier (CPF, CNPJ, CEP, phone or plate)',
    use: "package:mana_br (BR, BrFormat) — the client half of Mana.BR",
    names: RegExp(
      r'^(mask|format|isvalid|valid|validate|is|check|normalize|parse)\w*(cpf|cnpj|cep|plate|placa)\w*$',
      caseSensitive: false,
    ),
    patterns: [
      RegExp(r'\\d\{3\}\\?\.?\\d\{3\}\\?\.?\\d\{3\}'),
      RegExp(r'\\d\{2\}\\?\.?\\d\{3\}\\?\.?\\d\{3\}/?\\d\{4\}'),
      RegExp(r'\\d\{5\}-\??\\d\{3\}'),
      RegExp(r'\[A-Z\]\{3\}\[0-9\]'),
    ],
  ),
];

/// Apps use Mana primitives instead of re-deriving them: a hand-written mask,
/// validator or parser for something a primitive owns is reported with the
/// primitive to use.
final class UsePrimitives extends MultiAnalysisRule {
  UsePrimitives()
    : super(
        name: 'mana_use_primitives',
        description: 'Apps use the Mana primitive instead of reimplementing it.',
      );

  static const declaration = LintCode(
    'mana_use_primitives',
    "'{0}' reimplements {1}.",
    correctionMessage: 'Use {2}.',
    uniqueName: 'mana_use_primitives_declaration',
  );

  static const pattern = LintCode(
    'mana_use_primitives',
    'This pattern reimplements {0}.',
    correctionMessage: 'Use {1}.',
    uniqueName: 'mana_use_primitives_pattern',
  );

  @override
  List<DiagnosticCode> get diagnosticCodes => [declaration, pattern];

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final visitor = _Visitor(this);
    registry
      ..addFunctionDeclaration(this, visitor)
      ..addMethodDeclaration(this, visitor)
      ..addSimpleStringLiteral(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);
  final UsePrimitives rule;

  void _name(Token name) {
    for (final idiom in idioms) {
      if (idiom.names.hasMatch(name.lexeme)) {
        rule.reportAtToken(name, diagnosticCode: UsePrimitives.declaration, arguments: [name.lexeme, idiom.what, idiom.use]);
        return;
      }
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) => _name(node.name);

  @override
  void visitMethodDeclaration(MethodDeclaration node) => _name(node.name);

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    final creation = node.parent?.parent;
    final type = switch (creation) {
      InstanceCreationExpression(:final constructorName) => constructorName.type.name.lexeme,
      MethodInvocation(:final methodName) => methodName.name,
      _ => null,
    };
    if (type != 'RegExp') return;
    for (final idiom in idioms) {
      if (idiom.patterns.any((p) => p.hasMatch(node.value))) {
        rule.reportAtNode(node, diagnosticCode: UsePrimitives.pattern, arguments: [idiom.what, idiom.use]);
        return;
      }
    }
  }
}
