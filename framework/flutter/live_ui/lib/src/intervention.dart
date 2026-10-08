import 'dart:async';

import 'package:dio/dio.dart';

import 'configuration.dart';

/// What a network intervention makes a matching request answer — the AVP
/// conditions an adapter knows how to force.
enum NetCondition { offline, apiError, slow, empty }

/// One `net:<glob>=<condition>` rule: `net:/api/notifications/*=offline`,
/// `net:/api/operations/**=slow:1500`, `net:*=api-error`.
final class NetRule {
  NetRule(this.glob, this.condition, {this.delay = Duration.zero})
    : _pattern = _compile(glob);

  final String glob;
  final NetCondition condition;
  final Duration delay;
  final RegExp _pattern;

  bool matches(Uri uri) => _pattern.hasMatch(uri.path);

  static NetRule? parse(String rule) {
    final match = RegExp(r'^net:([^=]+)=([a-z-]+)(?::(\d+))?$')
        .firstMatch(rule.trim());
    if (match == null) return null;
    final condition = switch (match[2]) {
      'offline' => NetCondition.offline,
      'api-error' => NetCondition.apiError,
      'slow' => NetCondition.slow,
      'empty' => NetCondition.empty,
      _ => null,
    };
    if (condition == null) return null;
    return NetRule(
      match[1]!,
      condition,
      delay: Duration(milliseconds: int.tryParse(match[3] ?? '') ?? 1000),
    );
  }

  static RegExp _compile(String glob) {
    final out = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*' && i + 1 < glob.length && glob[i + 1] == '*') {
        out.write('.*');
        i++;
      } else if (c == '*') {
        out.write('[^/]*');
      } else {
        out.write(RegExp.escape(c));
      }
    }
    return RegExp('${out.toString()}\$');
  }
}

/// Interventions on a running app without editing it: requests matching a
/// rule answer as the network would under that condition, so a screen's
/// recovery (`Mana.Verbs` `offline:`/`retry:`, error states) can be seen and
/// verified. Rules come from `--dart-define=MANA_INTERVENE=<rule>;<rule>` or
/// [set]; only in Moments builds, never in a release.
final class MomentIntervention {
  MomentIntervention._();

  static List<NetRule> _rules = _fromEnvironment();

  static List<NetRule> get rules => List.unmodifiable(_rules);

  /// Replaces the rules (`[]` lifts every intervention).
  static void set(Iterable<String> rules) {
    _rules = [for (final r in rules) ?NetRule.parse(r)];
  }

  static List<NetRule> _fromEnvironment() {
    const raw = String.fromEnvironment('MANA_INTERVENE');
    return raw.isEmpty
        ? []
        : [for (final r in raw.split(';')) ?NetRule.parse(r)];
  }

  static void attach(Dio dio) {
    if (!momentsBuild) return;
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final rule = _rules.where((r) => r.matches(options.uri)).firstOrNull;
          switch (rule?.condition) {
            case null:
              handler.next(options);
            case NetCondition.offline:
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'intervention: offline',
                ),
              );
            case NetCondition.apiError:
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response(
                    requestOptions: options,
                    statusCode: 500,
                    data: {
                      'errors': [
                        {'code': 'intervention.api_error', 'status': '500'},
                      ],
                    },
                  ),
                ),
              );
            case NetCondition.slow:
              await Future<void>.delayed(rule!.delay);
              handler.next(options);
            case NetCondition.empty:
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'data': <Object>[]},
                ),
              );
          }
        },
      ),
    );
  }
}
