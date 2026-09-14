import 'dart:convert';

import 'package:http/http.dart' as http;

import '../diagnostics/app_log.dart';

const kDeepSeekBaseUrl = 'https://api.deepseek.com';
const kDeepSeekReasonerModel = 'deepseek-reasoner';
const kDeepSeekChatModel = 'deepseek-chat';

class DeepSeekMessage {
  const DeepSeekMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};

  factory DeepSeekMessage.system(String content) =>
      DeepSeekMessage(role: 'system', content: content);

  factory DeepSeekMessage.user(String content) =>
      DeepSeekMessage(role: 'user', content: content);

  factory DeepSeekMessage.assistant(String content) =>
      DeepSeekMessage(role: 'assistant', content: content);
}

class DeepSeekException implements Exception {
  const DeepSeekException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Direct DeepSeek chat API. Never log [apiKey] or Authorization headers.
class DeepSeekClient {
  DeepSeekClient({
    http.Client? httpClient,
    this.baseUrl = kDeepSeekBaseUrl,
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String baseUrl;

  Uri get _completionsUri => Uri.parse('$baseUrl/chat/completions');

  Future<String> chatCompletions({
    required String model,
    required List<DeepSeekMessage> messages,
    required String apiKey,
    int? maxTokens,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const DeepSeekException(
        'No DeepSeek API key. Add one in Settings.',
      );
    }
    if (messages.isEmpty) {
      throw const DeepSeekException('No messages to send.');
    }

    http.Response response;
    try {
      response = await _http
          .post(
            _completionsUri,
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': [for (final m in messages) m.toJson()],
              'max_tokens': ?maxTokens,
            }),
          )
          .timeout(timeout);
    } on DeepSeekException {
      rethrow;
    } catch (err) {
      AppLog.e('deepseek', 'DeepSeek call failed: network', err);
      throw DeepSeekException(_scrub('Could not reach DeepSeek. $err', key));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      AppLog.e(
        'deepseek',
        'DeepSeek call failed: HTTP ${response.statusCode}',
      );
      throw DeepSeekException(
        _httpMessage(response.statusCode, response.body, key),
        statusCode: response.statusCode,
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const DeepSeekException('DeepSeek returned an unexpected body.');
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const DeepSeekException('DeepSeek returned no choices.');
      }
      final first = choices.first;
      if (first is! Map) {
        throw const DeepSeekException('DeepSeek returned an empty choice.');
      }
      final message = first['message'];
      if (message is! Map) {
        throw const DeepSeekException('DeepSeek returned no message.');
      }
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }
      final reasoning = message['reasoning_content'];
      if (reasoning is String && reasoning.trim().isNotEmpty) {
        return reasoning.trim();
      }
      throw const DeepSeekException('DeepSeek returned an empty reply.');
    } on DeepSeekException {
      rethrow;
    } catch (err) {
      AppLog.e('deepseek', 'DeepSeek call failed: parse', err);
      throw DeepSeekException(
        _scrub('Could not read the DeepSeek reply. $err', key),
      );
    }
  }

  /// Cheap round-trip used by Settings. Uses [kDeepSeekChatModel].
  Future<void> testKey(String apiKey) async {
    await chatCompletions(
      model: kDeepSeekChatModel,
      messages: [DeepSeekMessage.user('Reply with the word ok.')],
      apiKey: apiKey,
      maxTokens: 8,
      timeout: const Duration(seconds: 20),
    );
  }
}

String _httpMessage(int status, String body, String apiKey) {
  switch (status) {
    case 401:
      return 'DeepSeek rejected the API key.';
    case 402:
      return 'DeepSeek balance is empty.';
    case 429:
      return 'DeepSeek rate-limited this key. Try again in a moment.';
    default:
      final snippet = _errorSnippet(body);
      if (snippet.isEmpty) {
        return 'DeepSeek HTTP $status.';
      }
      return _scrub('DeepSeek HTTP $status: $snippet', apiKey);
  }
}

String _errorSnippet(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map && error['message'] is String) {
        return (error['message'] as String).trim();
      }
      if (decoded['message'] is String) {
        return (decoded['message'] as String).trim();
      }
    }
  } catch (_) {
    // body is not JSON — fall through
  }
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.length <= 180 ? trimmed : trimmed.substring(0, 180);
}

String _scrub(String text, String apiKey) {
  var out = text;
  final key = apiKey.trim();
  if (key.isNotEmpty) {
    out = out.replaceAll(key, '***');
  }
  out = out.replaceAll(RegExp(r'Bearer\s+\S+'), 'Bearer ***');
  return out;
}
