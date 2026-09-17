import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_version.dart';

/// Stable hub door only — never v4./v5. generation hosts.
const kFieldReportUploadUrl = 'https://appbuilder.aml.one/api/field-reports';
const kFieldReportHealthUrl = 'https://appbuilder.aml.one/api/field-reports/health';

typedef FieldReportKind = String;

abstract final class FieldReportKinds {
  static const diagnosis = 'diagnosis';
  static const logcatExcerpt = 'logcat_excerpt';
  static const sessionLog = 'session_log';
  static const bugreport = 'bugreport';
}

class FieldReportUploadResult {
  const FieldReportUploadResult({
    required this.id,
    required this.projectId,
    required this.applicationId,
    required this.kind,
  });

  final String id;
  final String projectId;
  final String applicationId;
  final String kind;
}

class FieldReportUploadException implements Exception {
  FieldReportUploadException(this.code, {this.status});

  final String code;
  final int? status;

  @override
  String toString() => 'FieldReportUploadException($code, status=$status)';
}

/// Uploads Diagnostic captures to App Builder via the version-stable hub URL.
class FieldReportClient {
  FieldReportClient({http.Client? httpClient, this.uploadUrl = kFieldReportUploadUrl})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String uploadUrl;

  Future<bool> ping({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      final response = await _http
          .get(Uri.parse(kFieldReportHealthUrl))
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<FieldReportUploadResult> upload({
    required String applicationId,
    required FieldReportKind kind,
    String title = '',
    String deviceSerial = '',
    String textBody = '',
    Map<String, Object?>? payloadJson,
    File? attachment,
    String? toolVersion,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final packageId = applicationId.trim();
    if (packageId.isEmpty) {
      throw FieldReportUploadException('missing_application_id');
    }

    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    request.fields['applicationId'] = packageId;
    request.fields['kind'] = kind;
    if (title.trim().isNotEmpty) request.fields['title'] = title.trim();
    if (deviceSerial.trim().isNotEmpty) {
      request.fields['deviceSerial'] = deviceSerial.trim();
    }
    request.fields['toolVersion'] = (toolVersion ?? kAppVersion).trim();
    if (textBody.isNotEmpty) request.fields['textBody'] = textBody;
    if (payloadJson != null) {
      request.fields['payloadJson'] = jsonEncode(payloadJson);
    }
    if (attachment != null && await attachment.exists()) {
      request.files.add(
        await http.MultipartFile.fromPath('file', attachment.path),
      );
    }

    final streamed = await _http.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    final body = _tryJson(response.body);

    if (response.statusCode == 201) {
      return FieldReportUploadResult(
        id: '${body?['id'] ?? ''}',
        projectId: '${body?['projectId'] ?? ''}',
        applicationId: '${body?['applicationId'] ?? packageId}',
        kind: '${body?['kind'] ?? kind}',
      );
    }

    final error = '${body?['error'] ?? 'upload_failed'}';
    throw FieldReportUploadException(error, status: response.statusCode);
  }

  Map<String, dynamic>? _tryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }
}

String fieldReportUserMessage(FieldReportUploadException error) {
  switch (error.code) {
    case 'unknown_application_id':
      return 'This package is not an App Builder app.';
    case 'text_too_large':
    case 'attachment_too_large':
      return 'That report is too large to send.';
    case 'invalid_kind':
    case 'invalid_field_report':
      return 'Could not send that report.';
    case 'too_many_requests':
      return 'Too many uploads — try again in a bit.';
    default:
      return 'Could not reach App Builder (${error.code}).';
  }
}
