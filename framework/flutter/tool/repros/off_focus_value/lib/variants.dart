import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

late final SemanticsHandle semantics;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  semantics = WidgetsBinding.instance.ensureSemantics();
  runApp(const MaterialApp(home: Variants()));
}

class Variants extends StatefulWidget {
  const Variants({super.key});
  @override
  State<Variants> createState() => _VariantsState();
}

class _VariantsState extends State<Variants> {
  final multiline = TextEditingController(text: 'Line one\nLine two');
  final obscured = TextEditingController(text: 'synthetic');
  final locked = TextEditingController(text: 'Disabled initial');
  final readOnly = TextEditingController(text: 'Readonly initial');

  Iterable<TextEditingController> get controllers => [
    multiline,
    obscured,
    locked,
    readOnly,
  ];

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Off-focus variants')),
    body: Center(
      child: SizedBox(
        width: 560,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: multiline,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Multiline'),
            ),
            TextField(
              controller: obscured,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Obscured sample'),
            ),
            TextField(
              controller: locked,
              enabled: false,
              decoration: const InputDecoration(labelText: 'Disabled'),
            ),
            TextField(
              controller: readOnly,
              readOnly: true,
              decoration: const InputDecoration(labelText: 'Readonly'),
            ),
            FilledButton(
              onPressed: () {
                for (final controller in controllers) {
                  controller.clear();
                }
              },
              child: const Text('Clear all'),
            ),
            OutlinedButton(
              onPressed: () {
                multiline.text = 'New line one\nNew line two';
                obscured.text = 'example';
                locked.text = 'Disabled replacement';
                readOnly.text = 'Readonly replacement';
              },
              child: const Text('Replace all'),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: multiline,
              builder: (_, value, _) =>
                  Text('Multiline controller: "${value.text}"'),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: obscured,
              builder: (_, value, _) =>
                  Text('Obscured controller length: ${value.text.length}'),
            ),
          ],
        ),
      ),
    ),
  );
}
