import 'package:flutter/widgets.dart';

import 'currency.dart';

/// Independent display/input currency scope so users can pair any UI language
/// (`PT`, `EN`, `ES`) with any currency (`BRL`, `USD`, `EUR`).
final class ManaCurrencyScope extends InheritedWidget {
  const ManaCurrencyScope({
    required this.currency,
    required super.child,
    super.key,
  });

  final ManaCurrency currency;

  static ManaCurrency? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ManaCurrencyScope>()
        ?.currency;
  }

  static ManaCurrency of(
    BuildContext context, {
    ManaCurrency fallback = ManaCurrency.brl,
  }) => maybeOf(context) ?? fallback;

  @override
  bool updateShouldNotify(ManaCurrencyScope oldWidget) =>
      oldWidget.currency != currency;
}
