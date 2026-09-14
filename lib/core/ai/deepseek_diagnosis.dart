import 'deepseek_client.dart';
import 'evidence_bundle.dart';

const kDeepSeekDiagnosisSystemPrompt =
    'You are an expert Android ANR and performance engineer. '
    'You diagnose Application Not Responding stalls, input timeouts, jank, '
    'and main-thread blockage from traces, dumpsys, Perfetto, and logcat. '
    'Cite the evidence you use (stack frames, dumpsys numbers, Perfetto '
    'findings, logcat lines). Give concrete root causes ranked by likelihood, '
    'then concrete fixes (threading, binder, I/O, GPU, OEM quirks such as '
    'MIUI/HyperOS). If evidence is thin, say what is missing. Never invent '
    'stacks or metrics that are not in the evidence. Prefer short sections: '
    'Summary, Root cause, Evidence, Fixes, Next traces to capture.';

/// Reasoner for the first pass, chat for follow-up Q&A.
class DeepSeekDiagnosis {
  DeepSeekDiagnosis({DeepSeekClient? client})
    : _client = client ?? DeepSeekClient();

  final DeepSeekClient _client;

  Future<String> diagnose(EvidenceBundle bundle, String apiKey) {
    final evidence = bundle.text.trim();
    if (evidence.isEmpty) {
      throw const DeepSeekException('No diagnostic evidence to send.');
    }
    return _client.chatCompletions(
      model: kDeepSeekReasonerModel,
      messages: [
        DeepSeekMessage.system(kDeepSeekDiagnosisSystemPrompt),
        DeepSeekMessage.user(evidence),
      ],
      apiKey: apiKey,
      maxTokens: 8192,
      timeout: const Duration(seconds: 180),
    );
  }

  Future<String> followUp(
    List<DeepSeekMessage> history,
    String question,
    String apiKey,
  ) {
    final asked = question.trim();
    if (asked.isEmpty) {
      throw const DeepSeekException('Ask a follow-up question first.');
    }
    if (history.isEmpty) {
      throw const DeepSeekException(
        'Ask DeepSeek for an initial diagnosis before follow-ups.',
      );
    }
    return _client.chatCompletions(
      model: kDeepSeekChatModel,
      messages: [
        DeepSeekMessage.system(kDeepSeekDiagnosisSystemPrompt),
        ...history,
        DeepSeekMessage.user(asked),
      ],
      apiKey: apiKey,
      maxTokens: 2048,
      timeout: const Duration(seconds: 90),
    );
  }
}
