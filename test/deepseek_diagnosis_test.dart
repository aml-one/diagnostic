import 'dart:convert';

import 'package:diagnostic/core/ai/deepseek_client.dart';
import 'package:diagnostic/core/ai/deepseek_diagnosis.dart';
import 'package:diagnostic/core/ai/evidence_bundle.dart';
import 'package:diagnostic/core/diagnosis/diagnosis_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

void main() {
  test('diagnose uses deepseek-reasoner', () async {
    String? model;
    final service = DeepSeekDiagnosis(
      client: DeepSeekClient(
        httpClient: MockClient((request) async {
          model = (jsonDecode(request.body) as Map)['model'] as String;
          return Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Binder deadlock on main.'},
                },
              ],
            }),
            200,
          );
        }),
      ),
    );

    final reply = await service.diagnose(
      EvidenceBundle.fromReport(
        const DiagnosisReport(
          anrReason: 'Input dispatching timed out',
          process: 'one.aml.messageme',
        ),
      ),
      'sk-test',
    );
    expect(model, kDeepSeekReasonerModel);
    expect(reply, contains('Binder deadlock'));
  });

  test('followUp uses deepseek-chat and keeps history', () async {
    String? model;
    List<dynamic>? messages;
    final service = DeepSeekDiagnosis(
      client: DeepSeekClient(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          model = body['model'] as String;
          messages = body['messages'] as List<dynamic>;
          return Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'That frame is Choreographer.'},
                },
              ],
            }),
            200,
          );
        }),
      ),
    );

    final reply = await service.followUp(
      [
        DeepSeekMessage.user('evidence'),
        DeepSeekMessage.assistant('Main thread blocked.'),
      ],
      'Which frame?',
      'sk-test',
    );
    expect(model, kDeepSeekChatModel);
    expect(reply, contains('Choreographer'));
    expect(messages, isNotNull);
    expect(messages!.first['role'], 'system');
    expect(messages!.last['content'], 'Which frame?');
  });
}
