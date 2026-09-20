import '../adb/adb_client.dart';

/// One process row from `dumpsys cpuinfo`.
class CpuProcessRow {
  const CpuProcessRow({
    required this.percent,
    required this.pid,
    required this.name,
  });

  final double percent;
  final int? pid;
  final String name;
}

class CpuInfoSnapshot {
  const CpuInfoSnapshot({
    this.load,
    this.top = const [],
    this.rawExcerpt = '',
  });

  /// `Load: 1.2 / 1.1 / 1.0` when present.
  final String? load;
  final List<CpuProcessRow> top;
  final String rawExcerpt;
}

class MemInfoSnapshot {
  const MemInfoSnapshot({
    required this.package,
    this.totalPssKb,
    this.nativeHeapPssKb,
    this.dalvikHeapPssKb,
    this.rawExcerpt = '',
  });

  final String package;
  final int? totalPssKb;
  final int? nativeHeapPssKb;
  final int? dalvikHeapPssKb;
  final String rawExcerpt;
}

class GfxInfoSnapshot {
  const GfxInfoSnapshot({
    required this.package,
    this.totalFrames,
    this.jankyFrames,
    this.jankyPercent,
    this.rawExcerpt = '',
  });

  final String package;
  final int? totalFrames;
  final int? jankyFrames;
  final double? jankyPercent;
  final String rawExcerpt;
}

/// Quick `dumpsys` snapshots for Diagnose — no full bugreport.
class DumpsysSnapshot {
  DumpsysSnapshot({AdbClient? adb}) : _adb = adb ?? AdbClient();

  final AdbClient _adb;

  Future<GfxInfoSnapshot> gfxinfo(
    String serial,
    String package, {
    AdbCancelToken? cancel,
  }) async {
    final out = await _adb.shell(
      serial,
      'dumpsys gfxinfo $package',
      cancel: cancel,
    );
    return parseGfxInfo(out, package: package);
  }

  Future<MemInfoSnapshot> meminfo(
    String serial,
    String package, {
    AdbCancelToken? cancel,
  }) async {
    final out = await _adb.shell(
      serial,
      'dumpsys meminfo $package',
      cancel: cancel,
    );
    return parseMemInfo(out, package: package);
  }

  Future<CpuInfoSnapshot> cpuinfo(
    String serial, {
    AdbCancelToken? cancel,
  }) async {
    final out = await _adb.shell(serial, 'dumpsys cpuinfo', cancel: cancel);
    return parseCpuInfo(out);
  }

  Future<String> raw(
    String serial,
    String service, {
    AdbCancelToken? cancel,
  }) {
    return _adb.shell(serial, 'dumpsys $service', cancel: cancel);
  }
}

const _excerptCap = 4000;

GfxInfoSnapshot parseGfxInfo(String stdout, {required String package}) {
  int? total;
  int? janky;
  double? percent;
  for (final raw in stdout.split('\n')) {
    final line = raw.trim();
    final frames = _totalFrames.firstMatch(line);
    if (frames != null) total = int.tryParse(frames.group(1)!);
    final jank = _jankyFrames.firstMatch(line);
    if (jank != null) {
      janky = int.tryParse(jank.group(1)!);
      percent = double.tryParse(jank.group(2)!);
    }
  }
  return GfxInfoSnapshot(
    package: package,
    totalFrames: total,
    jankyFrames: janky,
    jankyPercent: percent,
    rawExcerpt: _cap(stdout),
  );
}

MemInfoSnapshot parseMemInfo(String stdout, {required String package}) {
  int? totalPss;
  int? native;
  int? dalvik;
  for (final raw in stdout.split('\n')) {
    final line = raw.trim();
    final total = _totalPss.firstMatch(line) ?? _totalLine.firstMatch(line);
    if (total != null) {
      totalPss ??= int.tryParse(total.group(1)!.replaceAll(',', ''));
    }
    final nat = _nativeHeap.firstMatch(line);
    if (nat != null) native ??= int.tryParse(nat.group(1)!.replaceAll(',', ''));
    final dal = _dalvikHeap.firstMatch(line);
    if (dal != null) dalvik ??= int.tryParse(dal.group(1)!.replaceAll(',', ''));
  }
  return MemInfoSnapshot(
    package: package,
    totalPssKb: totalPss,
    nativeHeapPssKb: native,
    dalvikHeapPssKb: dalvik,
    rawExcerpt: _cap(stdout),
  );
}

CpuInfoSnapshot parseCpuInfo(String stdout, {int topN = 8}) {
  String? load;
  final rows = <CpuProcessRow>[];
  for (final raw in stdout.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('Load:')) {
      load ??= line;
      continue;
    }
    final row = _cpuRow.firstMatch(line);
    if (row == null) continue;
    rows.add(
      CpuProcessRow(
        percent: double.tryParse(row.group(1)!) ?? 0,
        pid: int.tryParse(row.group(2)!),
        name: row.group(3)!.trim(),
      ),
    );
  }
  rows.sort((a, b) => b.percent.compareTo(a.percent));
  return CpuInfoSnapshot(
    load: load,
    top: List.unmodifiable(rows.take(topN)),
    rawExcerpt: _cap(stdout),
  );
}

String _cap(String text) {
  if (text.length <= _excerptCap) return text;
  return text.substring(0, _excerptCap);
}

/// Phone Diagnose cannot read another app's gfx/mem/cpu dumpsys without
/// root. Desktop Diagnose over USB still can.
const kOnDeviceLighterDiagnosis =
    'This is a lighter diagnosis which an unrooted phone allows us to do. For more thorough diagnostics use the Desktop app.';

bool dumpsysLooksDenied(String stdout) {
  final text = stdout.toLowerCase();
  return text.contains('permission denial') ||
      text.contains("can't dump") ||
      text.contains('cannot dump') ||
      text.contains('security exception');
}

/// Short Wi-Fi / P2P / connectivity notes for OneDrop Diagnose. Skips
/// denied dumpsys. Never returns the raw dump.
List<String> summarizeOneDropRadioDumpsys({
  required String wifi,
  required String p2p,
  required String connectivity,
}) {
  final out = <String>[];
  void add(String? finding) {
    if (finding == null || finding.isEmpty) return;
    if (out.contains(finding)) return;
    out.add(finding);
  }

  add(_radioDumpFinding('Wi-Fi', wifi, _wifiRadioFinding));
  add(_radioDumpFinding('Wi-Fi Direct', p2p, _p2pRadioFinding));
  add(_radioDumpFinding('Connectivity', connectivity, _connectivityRadioFinding));
  if (out.length <= 4) return out;
  return out.sublist(0, 4);
}

String? _radioDumpFinding(
  String label,
  String raw,
  String? Function(String) parse,
) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (dumpsysLooksDenied(text)) {
    return '$label dumpsys was denied on this device.';
  }
  return parse(_clipForScan(text));
}

String _clipForScan(String raw, [int max = 80000]) {
  if (raw.length <= max) return raw;
  return raw.substring(0, max);
}

String? _wifiRadioFinding(String raw) {
  final low = raw.toLowerCase();
  if (low.contains('wifi is disabled') ||
      RegExp(r'wifi.?enabled\s*[:=]\s*false', caseSensitive: false)
          .hasMatch(raw)) {
    return 'Wi-Fi is off — LAN OneDrop cannot announce.';
  }
  final ssid = RegExp(r'SSID:\s*"([^"]+)"').firstMatch(raw) ??
      RegExp(r'SSID:\s*(\S+)').firstMatch(raw);
  if (ssid != null) {
    final name = ssid.group(1)!.trim();
    if (name.isNotEmpty &&
        name != '<unknown ssid>' &&
        name != '0x' &&
        name.toLowerCase() != 'null') {
      return 'Wi-Fi connected as $name.';
    }
  }
  if (low.contains('wifi is enabled') ||
      RegExp(r'wifi.?enabled\s*[:=]\s*true', caseSensitive: false)
          .hasMatch(raw)) {
    return 'Wi-Fi is on.';
  }
  return null;
}

String? _p2pRadioFinding(String raw) {
  final low = raw.toLowerCase();
  if (low.contains('wifi p2p is disabled') ||
      low.contains('p2p is disabled')) {
    return 'Wi-Fi Direct is off.';
  }
  if (low.contains('group formed: true') ||
      low.contains('groupformed: true') ||
      (low.contains('wifi_p2p') && low.contains('connected'))) {
    return 'Wi-Fi Direct group is up.';
  }
  if (low.contains('no group') ||
      low.contains('group: null') ||
      low.contains('mgroup: null')) {
    return 'No Wi-Fi Direct group.';
  }
  return null;
}

String? _connectivityRadioFinding(String raw) {
  final low = raw.toLowerCase();
  if (RegExp(r'airplane.?mode[^:\n]{0,24}[:=]\s*(true|1|on)\b',
          caseSensitive: false)
      .hasMatch(raw)) {
    return 'Airplane mode is on.';
  }
  if (low.contains('no default network') ||
      low.contains('no active network') ||
      low.contains('active network: none')) {
    return 'No active network.';
  }
  if (RegExp(r'\btype:\s*WIFI\b', caseSensitive: false).hasMatch(raw) ||
      low.contains('active network is wifi') ||
      (low.contains('networkcapabilities') && low.contains('wifi'))) {
    if (low.contains('validated') || low.contains('connected')) {
      return 'Active network is Wi-Fi.';
    }
  }
  if (RegExp(r'\btype:\s*MOBILE\b', caseSensitive: false).hasMatch(raw) ||
      low.contains('cellular') && low.contains('connected')) {
    return 'Active network is mobile data — LAN OneDrop needs Wi-Fi.';
  }
  return null;
}

String? dumpsysGfxSummary(GfxInfoSnapshot? gfx) {
  if (gfx == null) return null;
  if (gfx.totalFrames != null) {
    final janky = gfx.jankyFrames ?? 0;
    final percent = gfx.jankyPercent;
    final pct = percent == null ? '' : ' (${percent.toStringAsFixed(1)}%)';
    return '${gfx.totalFrames} frames, $janky janky$pct';
  }
  if (dumpsysLooksDenied(gfx.rawExcerpt)) return null;
  final first = gfx.rawExcerpt.trim().split('\n').firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => '',
      );
  return first.isEmpty ? null : first;
}

String? dumpsysMemSummary(MemInfoSnapshot? mem) {
  if (mem == null) return null;
  if (mem.totalPssKb != null) {
    return 'Total PSS ${mem.totalPssKb} kB';
  }
  if (dumpsysLooksDenied(mem.rawExcerpt)) return null;
  return null;
}

String? dumpsysCpuSummary(CpuInfoSnapshot? cpu) {
  if (cpu == null) return null;
  if (cpu.load != null && cpu.load!.trim().isNotEmpty) return cpu.load;
  if (cpu.top.isNotEmpty) {
    final first = cpu.top.first;
    return '${first.percent.toStringAsFixed(1)}% ${first.name}';
  }
  if (dumpsysLooksDenied(cpu.rawExcerpt)) return null;
  return null;
}

final _totalFrames = RegExp(r'^Total frames rendered:\s*(\d+)');
final _jankyFrames = RegExp(
  r'^Janky frames:\s*(\d+)\s*\(\s*([0-9.]+)\s*%\s*\)',
);
final _totalPss = RegExp(r'TOTAL PSS:\s*([\d,]+)');
final _totalLine = RegExp(r'^TOTAL(?: PSS)?:\s*([\d,]+)');
final _nativeHeap = RegExp(r'^Native Heap:\s*([\d,]+)');
final _dalvikHeap = RegExp(
  r'^(?:Dalvik Heap|Java Heap):\s*([\d,]+)',
);
final _cpuRow = RegExp(
  r'^(\d+(?:\.\d+)?)%\s+(\d+)/([^:]+):',
);
