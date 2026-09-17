import 'dart:convert';

import 'adb_client.dart';

/// Rich identity for a connected device, read via `adb shell getprop`.
class AdbDeviceDetails {
  const AdbDeviceDetails({
    required this.serial,
    this.manufacturer,
    this.brand,
    this.model,
    this.marketName,
    this.androidVersion,
    this.isTablet = false,
  });

  final String serial;
  final String? manufacturer;
  final String? brand;
  final String? model;
  final String? marketName;
  final String? androidVersion;
  final bool isTablet;

  /// Best human manufacturer label (e.g. "Xiaomi", "Samsung").
  String get displayManufacturer {
    final raw = _firstNonEmpty([manufacturer, brand]);
    if (raw == null) return 'Unknown';
    return _titleCase(raw);
  }

  /// Marketing / model name for the card headline.
  String get displayModel =>
      _firstNonEmpty([marketName, model]) ?? 'Android device';

  /// Manufacturer + model, without doubling a brand that is already in the
  /// marketing name (`Xiaomi` + `Xiaomi 17 Ultra`).
  String get brandedModel {
    final model = displayModel;
    final mfr = displayManufacturer;
    if (mfr == 'Unknown') return model;
    if (model.toLowerCase().startsWith(mfr.toLowerCase())) return model;
    return '$mfr $model';
  }

  /// Watch / Diagnose header: `Xiaomi 17 Ultra (bbd6506e)`.
  String titleWithSerial({String? nickname}) {
    final trimmed = nickname?.trim();
    final name = (trimmed != null && trimmed.isNotEmpty)
        ? trimmed
        : brandedModel;
    if (name == serial) return serial;
    return '$name ($serial)';
  }

  String? get androidLabel {
    final version = androidVersion?.trim();
    if (version == null || version.isEmpty) return null;
    return 'Android $version';
  }

  static AdbDeviceDetails fallback(AdbDevice device) {
    return AdbDeviceDetails(
      serial: device.serial,
      model: device.model,
      marketName: device.model,
      brand: device.product,
      isTablet: _looksLikeTablet(
        '${device.model ?? ''} ${device.product ?? ''}',
      ),
    );
  }
}

/// Reads manufacturer / model / marketing name from a ready device.
Future<AdbDeviceDetails> readAdbDeviceDetails(
  AdbClient client,
  AdbDevice device,
) async {
  if (!device.isReady) {
    return AdbDeviceDetails.fallback(device);
  }

  try {
    final result = await client.run(
      const ['shell', 'getprop'],
      serial: device.serial,
    );
    final stdout = result.stdout.toString();
    if (result.exitCode != 0 && stdout.trim().isEmpty) {
      return AdbDeviceDetails.fallback(device);
    }

    final props = _parseGetprop(stdout);
    final manufacturer = _prop(props, const [
      'ro.product.manufacturer',
      'ro.product.brand',
    ]);
    final brand = _prop(props, const ['ro.product.brand']);
    final model = _prop(props, const [
      'ro.product.model',
      'ro.product.device',
      'ro.product.name',
    ]);
    final marketName = _prop(props, const [
      'ro.product.marketname',
      'ro.config.marketing_name',
      'ro.oplus.market.name',
      'ro.vendor.oplus.market.name',
      'ro.oppo.market.name',
      'persist.sys.device_name',
    ]);
    final androidVersion = _prop(props, const [
      'ro.build.version.release',
    ]);
    final characteristics = _prop(props, const [
      'ro.build.characteristics',
    ]);
    final probe =
        '${characteristics ?? ''} ${marketName ?? ''} ${model ?? ''} '
        '${device.model ?? ''} ${device.product ?? ''}';

    return AdbDeviceDetails(
      serial: device.serial,
      manufacturer: manufacturer,
      brand: brand,
      model: model ?? device.model,
      marketName: marketName,
      androidVersion: androidVersion,
      isTablet: _looksLikeTablet(probe),
    );
  } on Object {
    return AdbDeviceDetails.fallback(device);
  }
}

Map<String, String> _parseGetprop(String stdout) {
  final out = <String, String>{};
  final re = RegExp(r'^\[([^\]]+)\]: \[(.*)\]\s*$');
  for (final raw in const LineSplitter().convert(stdout)) {
    final match = re.firstMatch(raw.trim());
    if (match == null) continue;
    out[match.group(1)!] = match.group(2)!;
  }
  return out;
}

String? _prop(Map<String, String> props, List<String> keys) {
  for (final key in keys) {
    final value = props[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String? _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

bool _looksLikeTablet(String probe) {
  final lower = probe.toLowerCase();
  return lower.contains('tablet') ||
      lower.contains('tab_') ||
      lower.contains('tab-') ||
      lower.contains('gts') ||
      RegExp(r'\btab\b').hasMatch(lower);
}

String _titleCase(String raw) {
  if (raw.isEmpty) return raw;
  if (raw.length <= 3 && raw == raw.toUpperCase()) return raw.toUpperCase();
  return raw
      .split(RegExp(r'[\s_\-]+'))
      .where((part) => part.isNotEmpty)
      .map((part) {
        final lower = part.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ');
}
