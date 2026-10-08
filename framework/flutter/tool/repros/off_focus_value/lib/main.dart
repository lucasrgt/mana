import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

// Retain the handle for this application's lifetime. No Mana, backend, generated
// form, disabled fields or asynchronous submission participate in this repro.
late final SemanticsHandle semantics;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  semantics = WidgetsBinding.instance.ensureSemantics();
  runApp(const MaterialApp(home: Reproduction()));
}

class Reproduction extends StatefulWidget {
  const Reproduction({super.key});

  @override
  State<Reproduction> createState() => _ReproductionState();
}

class _ReproductionState extends State<Reproduction> {
  final first = TextEditingController(text: 'Initial first');
  final second = TextEditingController(text: 'Initial second');

  @override
  void dispose() {
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Off-focus field values')),
    body: Center(
      child: SizedBox(
        width: 560,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: first,
              decoration: const InputDecoration(labelText: 'First field'),
            ),
            TextField(
              controller: second,
              decoration: const InputDecoration(labelText: 'Second field'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                first.clear();
                second.clear();
              },
              child: const Text('Clear both'),
            ),
            OutlinedButton(
              onPressed: () {
                first.text = 'Replaced first';
                second.text = 'Replaced second';
              },
              child: const Text('Replace both'),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: first,
              builder: (_, value, _) =>
                  Text('First controller: "${value.text}"'),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: second,
              builder: (_, value, _) =>
                  Text('Second controller: "${value.text}"'),
            ),
          ],
        ),
      ),
    ),
  );
}
