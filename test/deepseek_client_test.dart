import 'dart:convert';

import 'package:diagnostic/core/ai/deepseek_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

void main() {
  test('posts chat completions without echoing the API key in errors', () async {
    late BaseRequest captured;
    final client = DeepSeekClient(
      httpClient: MockClient((request) async {
        captured = request;
        expect(request.url.toString(), 'https://api.deepseek.com/chat/completions');
        expect(request.headers['Authorization'], 'Bearer sk-secret-value');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], kDeepSeekReasonerModel);
        return Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Main thread blocked.'},
              },
            ],
          }),
          200,
        );
      }),
    );

    final text = await client.chatCompletions(
      model: kDeepSeekReasonerModel,
      messages: [DeepSeekMessage.user('evidence')],
      apiKey: 'sk-secret-value',
    );
    expect(text, 'Main thread blocked.');
    expect(captured.headers['Authorization'], contains('sk-secret-value'));
  });

  test('401 becomes a public error that does not include the key', () async {
    final client = DeepSeekClient(
      httpClient: MockClient((request) async {
        return Response(
          jsonEncode({
            'error': {'message': 'Invalid token sk-secret-value'},
          }),
          401,
        );
      }),
    );

    try {
      await client.chatCompletions(
        model: kDeepSeekChatModel,
        messages: [DeepSeekMessage.user('ping')],
        apiKey: 'sk-secret-value',
      );
      fail('expected DeepSeekException');
    } on DeepSeekException catch (err) {
      expect(err.statusCode, 401);
      expect(err.message, 'DeepSeek rejected the API key.');
      expect(err.toString(), isNot(contains('sk-secret-value')));
    }
  });

  test('scrubs the key from transport errors', () async {
    final client = DeepSeekClient(
      httpClient: MockClient((request) async {
        throw ClientException('refused for Bearer sk-secret-value');
      }),
    );

    try {
      await client.chatCompletions(
        model: kDeepSeekChatModel,
        messages: [DeepSeekMessage.user('ping')],
        apiKey: 'sk-secret-value',
      );
      fail('expected DeepSeekException');
    } on DeepSeekException catch (err) {
      expect(err.toString(), isNot(contains('sk-secret-value')));
      expect(err.toString(), contains('***'));
    }
  });

  test('empty key does not call the network', () async {
    var called = false;
    final client = DeepSeekClient(
      httpClient: MockClient((request) async {
        called = true;
        return Response('{}', 200);
      }),
    );

    expect(
      () => client.chatCompletions(
        model: kDeepSeekChatModel,
        messages: [DeepSeekMessage.user('ping')],
        apiKey: '  ',
      ),
      throwsA(isA<DeepSeekException>()),
    );
    expect(called, isFalse);
  });
}
