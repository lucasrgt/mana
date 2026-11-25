import 'package:flutter/foundation.dart';

import 'models.dart';

/// Async resolver callback producing the assistant's reply turn for a prompt.
typedef ManaAssistantResolver =
    Future<ManaChatTurn> Function(String prompt, String replyId, String threadId);

/// Headless multi-thread assistant state controller.
///
/// Manages thread creation, auto-titling from the first user prompt, history
/// switching, thinking states, intent completion, and voice listening status.
final class ManaAssistantController extends ChangeNotifier {
  ManaAssistantController({
    List<ManaChatThread> initialThreads = const [],
    String defaultThreadTitle = 'New thread',
    DateTime Function()? clock,
  }) : _defaultThreadTitle = defaultThreadTitle,
       _clock = clock ?? DateTime.now {
    if (initialThreads.isEmpty) {
      final first = ManaChatThread(
        id: _nextId('thread'),
        title: _defaultThreadTitle,
        updatedAt: _clock(),
      );
      _threads.add(first);
      _activeThreadId = first.id;
    } else {
      _threads.addAll(initialThreads);
      _activeThreadId = initialThreads.first.id;
    }
  }

  final String _defaultThreadTitle;
  final DateTime Function() _clock;
  final List<ManaChatThread> _threads = [];
  late String _activeThreadId;
  bool _isBusy = false;
  bool _isRecording = false;
  int _seq = 0;

  String _nextId(String prefix) => '$prefix-${++_seq}';

  List<ManaChatThread> get threads => List.unmodifiable(_threads);

  /// Non-empty threads suitable for a conversation history switcher.
  List<ManaChatThread> get historyThreads =>
      List.unmodifiable(_threads.where((t) => !t.isEmpty));

  String get activeThreadId => _activeThreadId;

  ManaChatThread get activeThread => _threads.firstWhere(
    (t) => t.id == _activeThreadId,
    orElse: () => _threads.first,
  );

  List<ManaChatTurn> get activeTurns => activeThread.turns;

  bool get isBusy => _isBusy;

  bool get isRecording => _isRecording;

  void setRecording(bool recording) {
    if (_isRecording == recording) return;
    _isRecording = recording;
    notifyListeners();
  }

  /// Starts a fresh empty thread (reuses the current one if already empty).
  ManaChatThread startNewThread({String? title}) {
    if (activeThread.isEmpty) return activeThread;
    final thread = ManaChatThread(
      id: _nextId('thread'),
      title: title ?? _defaultThreadTitle,
      updatedAt: _clock(),
    );
    _threads.insert(0, thread);
    _activeThreadId = thread.id;
    _isBusy = false;
    _isRecording = false;
    notifyListeners();
    return thread;
  }

  void selectThread(String threadId) {
    if (_activeThreadId == threadId) return;
    if (_threads.every((t) => t.id != threadId)) return;
    _activeThreadId = threadId;
    notifyListeners();
  }

  void deleteThread(String threadId) {
    _threads.removeWhere((t) => t.id == threadId);
    if (_threads.isEmpty) {
      final fresh = ManaChatThread(
        id: _nextId('thread'),
        title: _defaultThreadTitle,
        updatedAt: _clock(),
      );
      _threads.add(fresh);
      _activeThreadId = fresh.id;
    } else if (_activeThreadId == threadId) {
      _activeThreadId = _threads.first.id;
    }
    notifyListeners();
  }

  /// Marks an embedded action intent inside a turn as completed.
  void markIntentCompleted(String turnId, String intentId) {
    final tIdx = _threads.indexWhere((t) => t.id == _activeThreadId);
    if (tIdx < 0) return;
    final thread = _threads[tIdx];
    final nextTurns = [
      for (final turn in thread.turns)
        if (turn.id == turnId)
          turn.copyWith(
            intents: [
              for (final intent in turn.intents)
                if (intent.id == intentId)
                  intent.copyWith(completed: true)
                else
                  intent,
            ],
          )
        else
          turn,
    ];
    _threads[tIdx] = thread.copyWith(turns: nextTurns);
    notifyListeners();
  }

  /// Appends the user prompt + thinking placeholder, resolves asynchronously
  /// via [resolver], and replaces the placeholder with the resolved turn.
  Future<void> send(
    String rawPrompt, {
    required ManaAssistantResolver resolver,
  }) async {
    final prompt = rawPrompt.trim();
    if (prompt.isEmpty || _isBusy) return;

    final threadId = _activeThreadId;
    final userId = _nextId('u');
    final replyId = _nextId('a');
    final now = _clock();

    _isBusy = true;
    _mutateThread(threadId, (thread) {
      final nextTitle = thread.isEmpty ? _deriveTitle(prompt) : thread.title;
      return thread.copyWith(
        title: nextTitle,
        updatedAt: now,
        turns: [
          ...thread.turns,
          ManaChatTurn(
            id: userId,
            isUser: true,
            text: prompt,
            createdAt: now,
          ),
          ManaChatTurn(
            id: replyId,
            isUser: false,
            text: '',
            createdAt: now,
            thinking: true,
          ),
        ],
      );
    });

    try {
      final resolved = await resolver(prompt, replyId, threadId);
      _mutateThread(threadId, (thread) {
        final turns = [
          for (final t in thread.turns) if (t.id == replyId) resolved else t,
        ];
        return thread.copyWith(updatedAt: _clock(), turns: turns);
      });
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  void _mutateThread(
    String threadId,
    ManaChatThread Function(ManaChatThread) transform,
  ) {
    final idx = _threads.indexWhere((t) => t.id == threadId);
    if (idx < 0) return;
    _threads[idx] = transform(_threads[idx]);
    notifyListeners();
  }

  String _deriveTitle(String prompt) {
    final clean = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= 36) return clean;
    return '${clean.substring(0, 36).trim()}...';
  }
}
