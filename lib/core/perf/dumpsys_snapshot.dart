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
