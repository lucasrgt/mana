import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'package:analyzer/error/error.dart';

/// Screens compose the design system: no Material or Cupertino control, no
/// literal colour and no literal spacing outside it.
final class DesignSystemOnly extends MultiAnalysisRule {
  DesignSystemOnly()
    : super(
        name: 'mana_design_system_only',
        description:
            'Screens use design-system components and tokens, never raw '
            'Material/Cupertino controls, colours or spacing.',
      );

  static const control = LintCode(
    'mana_design_system_only',
    "'{0}' is a raw {1} control.",
    correctionMessage: 'Use the design-system component for it.',
    uniqueName: 'mana_design_system_only_control',
  );

  static const colour = LintCode(
    'mana_design_system_only',
    'A literal colour bypasses the theme.',
    correctionMessage: 'Read the colour from the design-system tokens.',
    uniqueName: 'mana_design_system_only_colour',
  );

  static const spacing = LintCode(
    'mana_design_system_only',
    'A literal size bypasses the spacing scale.',
    correctionMessage: 'Use a design-system spacing token.',
    uniqueName: 'mana_design_system_only_spacing',
  );

  @override
  List<DiagnosticCode> get diagnosticCodes => [control, colour, spacing];

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final visitor = _Visitor(this);
    registry
      ..addInstanceCreationExpression(this, visitor)
      ..addMethodInvocation(this, visitor)
      ..addPrefixedIdentifier(this, visitor);
  }
}

const _controls = {
  'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton', 'IconButton',
  'FloatingActionButton', 'TextField', 'TextFormField', 'Checkbox', 'Switch',
  'Radio', 'Slider', 'DropdownButton', 'DropdownMenu', 'AlertDialog',
  'SimpleDialog', 'Dialog', 'SnackBar', 'Chip', 'ListTile', 'Card',
  'BottomSheet', 'NavigationBar', 'TabBar', 'CupertinoButton',
  'CupertinoTextField', 'CupertinoSwitch', 'CupertinoAlertDialog',
};

const _overlays = {'showDialog', 'showModalBottomSheet', 'showCupertinoDialog', 'showDatePicker'};

String? _flutterLibrary(Element? element) {
  final uri = element?.library?.uri.toString() ?? '';
  if (uri.startsWith('package:flutter/src/material/')) return 'Material';
  if (uri.startsWith('package:flutter/src/cupertino/')) return 'Cupertino';
  return null;
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);
  final DesignSystemOnly rule;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.element;
    final name = type?.name;
    final library = _flutterLibrary(type);
    if (name == null) return;
    if (library != null && _controls.contains(name)) {
      rule.reportAtNode(node.constructorName, diagnosticCode: DesignSystemOnly.control, arguments: [name, library]);
    } else if (name == 'Color' && (type?.library?.uri.toString() ?? '').startsWith('dart:ui')) {
      rule.reportAtNode(node, diagnosticCode: DesignSystemOnly.colour);
    } else if (_literalSpacing(name, node.argumentList)) {
      rule.reportAtNode(node, diagnosticCode: DesignSystemOnly.spacing);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (_overlays.contains(node.methodName.name) && _flutterLibrary(element) != null) {
      rule.reportAtNode(node.methodName, diagnosticCode: DesignSystemOnly.control, arguments: [node.methodName.name, _flutterLibrary(element)!]);
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final owner = node.prefix.element;
    if (owner is InterfaceElement && owner.name == 'Colors' && _flutterLibrary(owner) == 'Material' && node.identifier.name != 'transparent') {
      rule.reportAtNode(node, diagnosticCode: DesignSystemOnly.colour);
    }
  }

  static bool _literalSpacing(String type, ArgumentList arguments) {
    bool literal(Expression e) => e is IntegerLiteral || e is DoubleLiteral;
    return switch (type) {
      'EdgeInsets' || 'EdgeInsetsDirectional' => arguments.arguments.any(
        (a) => literal(a.argumentExpression),
      ),
      'SizedBox' => arguments.arguments.any(
        (a) => a is NamedArgument && const {'width', 'height'}.contains(a.name.lexeme) && literal(a.argumentExpression),
      ),
      _ => false,
    };
  }
}
