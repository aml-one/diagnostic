import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ai/deepseek_client.dart';
import '../core/ai/deepseek_diagnosis.dart';
import '../core/ai/evidence_bundle.dart';
import '../core/diagnosis/diagnosis_report.dart';
import '../core/diagnostics/app_log.dart';
import '../services/settings_store.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

final deepSeekClientProvider = Provider<DeepSeekClient>((ref) => DeepSeekClient());

final deepSeekDiagnosisServiceProvider = Provider<DeepSeekDiagnosis>((ref) {
  return DeepSeekDiagnosis(client: ref.watch(deepSeekClientProvider));
});

/// Stored key from Windows Credential Manager. Empty string if none.
final deepSeekApiKeyProvider =
    AsyncNotifierProvider<DeepSeekApiKeyController, String>(
      DeepSeekApiKeyController.new,
    );

final hasDeepSeekApiKeyProvider = Provider<bool>((ref) {
  final key = ref.watch(deepSeekApiKeyProvider).valueOrNull ?? '';
  return key.trim().isNotEmpty;
});

class DeepSeekApiKeyController extends AsyncNotifier<String> {
  @override
  Future<String> build() {
    return ref.read(settingsStoreProvider).deepSeekApiKey();
  }

  Future<void> save(String value) async {
    await ref.read(settingsStoreProvider).setDeepSeekApiKey(value);
    state = AsyncData(await ref.read(settingsStoreProvider).deepSeekApiKey());
  }

  Future<void> test(String? typedKey) async {
    final typed = typedKey?.trim() ?? '';
    final stored = state.valueOrNull ?? '';
    final key = typed.isNotEmpty ? typed : stored;
    await ref.read(deepSeekClientProvider).testKey(key);
  }
}

class DeepSeekChatTurn {
  const DeepSeekChatTurn({required this.role, required this.content});

  final String role;
  final String content;
}

class DeepSeekDiagnosisView {
  const DeepSeekDiagnosisView({
    this.busy = false,
    this.error,
    this.diagnosis,
    this.followUps = const [],
  });

  final bool busy;
  final String? error;
  final String? diagnosis;
  final List<DeepSeekChatTurn> followUps;

  bool get hasReply => diagnosis != null && diagnosis!.trim().isNotEmpty;
}

/// Report screen watches this. Call [ask] from "Ask DeepSeek".
final deepSeekDiagnosisControllerProvider =
    NotifierProvider<DeepSeekDiagnosisController, DeepSeekDiagnosisView>(
      DeepSeekDiagnosisController.new,
    );

class DeepSeekDiagnosisController extends Notifier<DeepSeekDiagnosisView> {
  List<DeepSeekMessage> _history = [];

  @override
  DeepSeekDiagnosisView build() => const DeepSeekDiagnosisView();

  void reset() {
    _history = [];
    state = const DeepSeekDiagnosisView();
  }

  Future<void> ask(DiagnosisEvidence evidence) async {
    if (!evidence.hasEvidence) {
      state = const DeepSeekDiagnosisView(
        error: 'No ANR evidence yet. Capture a trace first.',
      );
      return;
    }
    final key = (await ref.read(deepSeekApiKeyProvider.future)).trim();
    if (key.isEmpty) {
      state = const DeepSeekDiagnosisView(
        error: 'Add a DeepSeek API key in Settings first.',
      );
      return;
    }
    state = const DeepSeekDiagnosisView(busy: true);
    try {
      final bundle = EvidenceBundle.fromEvidence(evidence);
      final reply = await ref
          .read(deepSeekDiagnosisServiceProvider)
          .diagnose(bundle, key);
      _history = [
        DeepSeekMessage.user(bundle.text),
        DeepSeekMessage.assistant(reply),
      ];
      state = DeepSeekDiagnosisView(diagnosis: reply);
    } catch (err) {
      AppLog.e('deepseek', 'DeepSeek call failed: ${_publicError(err)}', err);
      _history = [];
      state = DeepSeekDiagnosisView(error: _publicError(err));
    }
  }

  Future<void> followUp(String question) async {
    final asked = question.trim();
    if (asked.isEmpty) return;
    if (_history.isEmpty) {
      state = state.hasReply
          ? DeepSeekDiagnosisView(
              diagnosis: state.diagnosis,
              followUps: state.followUps,
              error: 'Ask DeepSeek for an initial diagnosis before follow-ups.',
            )
          : const DeepSeekDiagnosisView(
              error: 'Ask DeepSeek for an initial diagnosis before follow-ups.',
            );
      return;
    }
    final key = (await ref.read(deepSeekApiKeyProvider.future)).trim();
    if (key.isEmpty) {
      state = DeepSeekDiagnosisView(
        diagnosis: state.diagnosis,
        followUps: state.followUps,
        error: 'Add a DeepSeek API key in Settings first.',
      );
      return;
    }
    final previous = state;
    state = DeepSeekDiagnosisView(
      busy: true,
      diagnosis: previous.diagnosis,
      followUps: previous.followUps,
    );
    try {
      final reply = await ref
          .read(deepSeekDiagnosisServiceProvider)
          .followUp(_history, asked, key);
      _history = [
        ..._history,
        DeepSeekMessage.user(asked),
        DeepSeekMessage.assistant(reply),
      ];
      state = DeepSeekDiagnosisView(
        diagnosis: previous.diagnosis,
        followUps: [
          ...previous.followUps,
          DeepSeekChatTurn(role: 'user', content: asked),
          DeepSeekChatTurn(role: 'assistant', content: reply),
        ],
      );
    } catch (err) {
      AppLog.e('deepseek', 'DeepSeek call failed: ${_publicError(err)}', err);
      state = DeepSeekDiagnosisView(
        diagnosis: previous.diagnosis,
        followUps: previous.followUps,
        error: _publicError(err),
      );
    }
  }
}

String _publicError(Object err) {
  if (err is DeepSeekException) return err.message;
  return 'DeepSeek request failed.';
}
