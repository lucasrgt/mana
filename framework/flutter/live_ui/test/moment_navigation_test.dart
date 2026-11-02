import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_ui/live_ui.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// GoRouter's two calls: `go` replaces the stack, `push` adds a screen on top.
final class _Router extends ChangeNotifier {
  List<String> stack = const ['/create'];
  String get location => stack.last;

  void go(String route) {
    stack = [route];
    notifyListeners();
  }

  void push(String route) {
    stack = [...stack, route];
    notifyListeners();
  }

  void pop() {
    stack = stack.sublist(0, stack.length - 1);
    notifyListeners();
  }
}

/// The app's Moments wiring: one binding whose projection names the screen
/// on top, captured after every router change.
final class _Flow extends StatefulWidget {
  const _Flow({required this.router, required this.screen});
  final _Router router;
  final Widget Function(String route) screen;

  @override
  State<_Flow> createState() => _FlowState();
}

final class _FlowState extends State<_Flow> {
  final _scroll = ScrollController();
  late final _binding = MomentViewBinding(
    route: '/flow',
    scroll: _scroll,
    read: () => {'destination': widget.router.location},
    restore: (_) {},
  );

  @override
  void initState() {
    super.initState();
    widget.router.addListener(_changed);
  }

  void _changed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    _binding.attach(context, ready: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _binding.capture();
    });
    return Navigator(
      pages: [
        for (final (index, route) in widget.router.stack.indexed)
          MaterialPage<void>(
            key: ValueKey('$index$route'),
            child: widget.screen(route),
          ),
      ],
      onDidRemovePage: (_) {},
    );
  }

  @override
  void dispose() {
    widget.router.removeListener(_changed);
    _binding.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

/// A screen whose control offers [verb] once [loaded] completes.
final class _Screen extends StatefulWidget {
  const _Screen({required this.verb, required this.loaded, this.onCreate});
  final String verb;
  final Future<void> loaded;
  final VoidCallback? onCreate;

  @override
  State<_Screen> createState() => _ScreenState();
}

final class _ScreenState extends State<_Screen> {
  void Function()? _withdraw;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.loaded.then((_) {
        if (mounted) _withdraw = MomentAffordances.offer(widget.verb);
      }),
    );
  }

  @override
  void dispose() {
    _withdraw?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(onPressed: widget.onCreate, child: Text(widget.verb)),
  );
}

void main() {
  testWidgets(
    'a go and a push after a request reach the runner as the screen on top, '
    'whatever the screen offers while the report is in flight',
    (tester) async {
      MomentAffordances.enable();
      addTearDown(MomentAffordances.disable);
      final router = _Router();
      final saved = Completer<void>(), viewLoaded = Completer<void>();
      final heldReply = Completer<void>();
      // What the runner shows a journey: the last report it accepted. It
      // accepts every observe, as it reached it; a capture must be newer.
      Map<String, dynamic>? shown;
      var lastCapture = 0;
      final arrivals = <String>[];
      var inFlight = 0, mostInFlight = 0;
      final idle = Completer<http.Response>();
      var polls = 0;
      final controller = MomentController(
        navigate: (_) {},
        client: MockClient((request) async {
          if (request.method == 'GET') {
            if (++polls > 1) return idle.future;
            return http.Response(
              jsonEncode({
                'revision': 'r1',
                'state': {
                  'name': 'create',
                  'projection': {
                    'route': '/flow',
                    'destination': '/create',
                    'scrollOffset': 0,
                  },
                },
              }),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final projection = body['projection'] as Map<String, dynamic>;
          final op = request.url.path.split('/').last;
          if (op == 'capture') {
            if ((body['sequence'] as int) <= lastCapture) {
              return http.Response('{}', 409);
            }
            lastCapture = body['sequence'] as int;
          }
          arrivals.add('$op ${projection['destination']}');
          shown = projection;
          mostInFlight = max(mostInFlight, ++inFlight);
          // A loaded runner answers the first report of the new screen late.
          if (projection['destination'] == '/view' && !heldReply.isCompleted) {
            await heldReply.future;
          }
          inFlight--;
          return http.Response('{}', 200);
        }),
      );
      Widget screen(String route) => switch (route) {
        '/create' => _Screen(
          verb: 'service.create',
          loaded: Future.value(),
          onCreate: () async {
            await saved.future;
            router
              ..go('/detail')
              ..push('/view');
          },
        ),
        '/detail' => _Screen(verb: 'property.edit:1', loaded: Future.value()),
        _ => _Screen(verb: 'service.edit:1', loaded: viewLoaded.future),
      };
      await tester.pumpWidget(
        MomentScope(
          controller: controller,
          child: MaterialApp(
            home: _Flow(router: router, screen: screen),
          ),
        ),
      );
      final connected = controller.connect(
        Uri.parse('http://127.0.0.1:18741'),
        'local-test',
      );
      await tester.pumpAndSettle();
      expect(shown?['destination'], '/create');

      await tester.tap(find.text('service.create'));
      saved.complete();
      await tester.pumpAndSettle();
      expect(arrivals, contains('capture /view'));
      // The new screen loads its record and offers its verb while the
      // runner still holds the reply to the report of that screen.
      viewLoaded.complete();
      await tester.pumpAndSettle();
      heldReply.complete();
      await tester.pumpAndSettle();
      expect(shown?['destination'], '/view', reason: arrivals.join(', '));
      expect(shown?['destination'], router.location);
      expect(mostInFlight, 1, reason: 'Two reports could land in either order');

      router.pop();
      await tester.pumpAndSettle();
      expect(shown?['destination'], '/detail', reason: arrivals.join(', '));

      controller.dispose();
      idle.complete(http.Response('', 204));
      await tester.pump();
      await connected;
    },
  );
}
