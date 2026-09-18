import 'dart:convert';

import 'phone_diagnostic.dart';

/// UTF-8 JSON envelope + newline + body (raw logcat for `.mdx`, JSON for `.mdxd`).
class MdxHeader {
  const MdxHeader({
    this.magic = kMdxMagic,
    required this.toolVersion,
    required this.device,
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.deviceName = '',
    this.appLabel = '',
    this.sdk = 0,
    required this.packages,
    required this.levels,
    required this.startedAt,
    this.stoppedAt,
    this.source = 'logcat',
  });

  final String magic;
  final String toolVersion;
  final String device;
  final String manufacturer;
  final String brand;
  final String model;
  final String deviceName;
  final String appLabel;
  final int sdk;
  final List<String> packages;
  final String levels;
  final String startedAt;
  final String? stoppedAt;
  final String source;

  bool get isDiagnosis => magic == kMdxdMagic;

  Map<String, Object?> toJson() => {
        'magic': magic,
        'toolVersion': toolVersion,
        'device': device,
        'manufacturer': manufacturer,
        if (brand.isNotEmpty) 'brand': brand,
        if (model.isNotEmpty) 'model': model,
        if (deviceName.isNotEmpty) 'deviceName': deviceName,
        if (appLabel.isNotEmpty) 'appLabel': appLabel,
        'sdk': sdk,
        'packages': packages,
        'levels': levels,
        'startedAt': startedAt,
        if (stoppedAt != null) 'stoppedAt': stoppedAt,
        'source': source,
      };

  factory MdxHeader.fromJson(Map<String, Object?> json) {
    final packages = json['packages'];
    final model = json['model'] as String? ?? '';
    final device = json['device'] as String? ?? '';
    return MdxHeader(
      magic: json['magic'] as String? ?? '',
      toolVersion: json['toolVersion'] as String? ?? '',
      device: device,
      manufacturer: json['manufacturer'] as String? ?? '',
      brand: json['brand'] as String? ?? '',
      model: model.isNotEmpty ? model : device,
      deviceName: json['deviceName'] as String? ?? '',
      appLabel: json['appLabel'] as String? ?? '',
      sdk: json['sdk'] as int? ?? 0,
      packages: packages is List
          ? packages.map((item) => '$item').toList(growable: false)
          : const [],
      levels: json['levels'] as String? ?? '',
      startedAt: json['startedAt'] as String? ?? '',
      stoppedAt: json['stoppedAt'] as String?,
      source: json['source'] as String? ?? 'logcat',
    );
  }
}

class MdxDocument {
  const MdxDocument({required this.header, required this.body});

  final MdxHeader header;
  final String body;

  String encode() => '${jsonEncode(header.toJson())}\n$body';
}

/// Split a `.mdx` / `.mdxd` file into header + body. Throws [FormatException]
/// if the first line is not a JSON object with magic `MDX1` or `MDXD1`.
MdxDocument parseMdx(String raw) {
  final split = raw.indexOf('\n');
  final head = split < 0 ? raw : raw.substring(0, split);
  final body = split < 0 ? '' : raw.substring(split + 1);
  final decoded = jsonDecode(head);
  if (decoded is! Map) {
    throw const FormatException('MDX header is not a JSON object');
  }
  final header = MdxHeader.fromJson(
    decoded.map((key, value) => MapEntry('$key', value)),
  );
  if (header.magic != kMdxMagic && header.magic != kMdxdMagic) {
    throw FormatException('Unknown MDX magic: ${header.magic}');
  }
  return MdxDocument(header: header, body: body);
}

String composeMdx({
  required MdxHeader header,
  required String body,
}) =>
    MdxDocument(header: header, body: body).encode();
