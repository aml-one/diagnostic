import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One thread from a traces / dumpstate ANR dump.
class ThreadDump {
  const ThreadDump({
    required this.name,
    required this.state,
    required this.stackFrames,
    required this.isMain,
  });

  final String name;
  final String state;
  final List<String> stackFrames;
  final bool isMain;
}

/// One ANR (or traces.txt pid block) extracted from a bugreport.
class AnrTrace {
  const AnrTrace({
    this.process,
    this.packageName,
    this.subject,
    this.reason,
    this.timestamp,
    this.threads = const [],
    this.lockedStacks = const [],
    this.rawExcerpt = '',
  });

  final String? process;
  final String? packageName;
  final String? subject;
  final String? reason;
  final DateTime? timestamp;
  final List<ThreadDump> threads;
  final List<String> lockedStacks;
  final String rawExcerpt;
}

/// Parsed bugreport ANR evidence plus optional CPU / mem / gfx excerpts.
class BugreportParseResult {
  const BugreportParseResult({
    this.anrs = const [],
    this.cpuSummary,
    this.memSummary,
    this.gfxSummary,
  });

  final List<AnrTrace> anrs;
  final String? cpuSummary;
  final String? memSummary;
  final String? gfxSummary;

  /// Most recent ANR, optionally matching [packageFilter] (process or package).
  AnrTrace? preferredAnr([String? packageFilter]) {
    var list = anrs;
    final needle = packageFilter?.trim();
    if (needle != null && needle.isNotEmpty) {
      final filtered = anrs.where((anr) => _matchesPackage(anr, needle)).toList();
      if (filtered.isNotEmpty) list = filtered;
    }
    if (list.isEmpty) return null;
    final ranked = [...list]..sort((a, b) {
      final at = a.timestamp;
      final bt = b.timestamp;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return ranked.first;
  }
}

bool _matchesPackage(AnrTrace anr, String needle) {
  bool hit(String? value) =>
      value != null && value.toLowerCase().contains(needle.toLowerCase());
  return hit(anr.packageName) || hit(anr.process);
}

/// Line-scans extracted bugreport files without loading whole dumps into RAM.
class AnrTraceParser {
  AnrTraceParser._();

  static const int excerptCap = 12000;
  static const int summaryLineCap = 48;
  static const int maxAnrs = 24;
  static const int maxThreads = 24;
  static const int maxFrames = 40;
  static const int maxLocked = 24;

  /// Scan [extractDir] for dumpstate / traces / ANR files, then parse them.
  static Future<BugreportParseResult> parseExtractDir(
    String extractDir, {
    String? packageFilter,
  }) async {
    final dir = Directory(extractDir);
    if (!dir.existsSync()) {
      return const BugreportParseResult();
    }
    final files = await discoverParseTargets(dir);
    final merged = _MergeSink();
    for (final file in files) {
      try {
        await _parseFileInto(file, merged);
      } on Object {
        // Skip unreadable / binary-ish artifacts; keep scanning the rest.
      }
    }
    final result = merged.toResult();
    final preferred = result.preferredAnr(packageFilter);
    if (preferred == null ||
        (result.anrs.isNotEmpty && identical(preferred, result.anrs.first))) {
      return result;
    }
    return BugreportParseResult(
      anrs: [preferred, ...result.anrs.where((anr) => !identical(anr, preferred))],
      cpuSummary: result.cpuSummary,
      memSummary: result.memSummary,
      gfxSummary: result.gfxSummary,
    );
  }

  /// Parse a small in-memory dump (tests / already-capped excerpts).
  static BugreportParseResult parseText(String text) {
    final merged = _MergeSink();
    final scan = _FileScan();
    for (final raw in const LineSplitter().convert(text)) {
      scan.add(raw, merged);
    }
    scan.flush(merged);
    return merged.toResult();
  }

  static Future<void> _parseFileInto(File file, _MergeSink merged) async {
    final scan = _FileScan();
    // Bugreports often contain Latin-1 / OEM bytes mixed into UTF-8 text.
    // Strict utf8.decoder throws FormatException mid-file and aborts Diagnose.
    try {
      final stream = file
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      await for (final line in stream) {
        scan.add(line, merged);
      }
    } on FormatException {
      // allowMalformed should already swallow bad bytes; if a decoder still
      // throws, fall back to Latin-1 so Diagnose keeps going.
      final raw = await file.readAsBytes();
      final text = String.fromCharCodes(raw);
      for (final line in const LineSplitter().convert(text)) {
        scan.add(line, merged);
      }
    }
    scan.flush(merged);
  }

  /// Text files worth scanning: dumpstate, bugreport-*.txt, traces, FS/data/anr.
  static Future<List<File>> discoverParseTargets(Directory extractDir) async {
    final files = <File>[];
    await _walk(extractDir, extractDir, files);
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static Future<void> _walk(
    Directory root,
    Directory dir,
    List<File> out,
  ) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        final name = p.basename(entity.path).toLowerCase();
        if (_skipDirNames.contains(name)) continue;
        await _walk(root, entity, out);
      } else if (entity is File && _shouldScan(root, entity)) {
        out.add(entity);
      }
    }
  }

  static bool _shouldScan(Directory root, File file) {
    final name = p.basename(file.path).toLowerCase();
    if (_skipFileSuffixes.any(name.endsWith)) return false;
    if (name.endsWith('.txt') || name.endsWith('.log')) {
      return name.contains('dumpstate') ||
          name.startsWith('bugreport') ||
          name.contains('traces') ||
          name.startsWith('anr') ||
          name == 'main_entry.txt';
    }
    final parent = p.basename(p.dirname(file.path)).toLowerCase();
    if (parent == 'anr') return true;
    if (name.startsWith('anr_') || name == 'traces.txt') return true;
    final rel = p
        .relative(file.path, from: root.path)
        .replaceAll('\\', '/')
        .toLowerCase();
    if (rel.contains('/anr/') || rel.contains('fs_dumpstate')) {
      return !name.contains('.');
    }
    return false;
  }
}

const _skipDirNames = {
  'proto',
  'camera',
  'wifi',
  'modem',
  'bluetooth',
  'wlan',
};

const _skipFileSuffixes = [
  '.proto',
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.zip',
  '.bin',
  '.pb',
  '.gz',
  '.html',
];

class _MergeSink {
  final anrs = <AnrTrace>[];
  String? cpuSummary;
  String? memSummary;
  String? gfxSummary;

  void addAnr(AnrTrace anr) {
    if (anrs.length >= AnrTraceParser.maxAnrs) return;
    if (anr.process == null &&
        anr.packageName == null &&
        anr.reason == null &&
        anr.threads.isEmpty) {
      return;
    }
    anrs.add(anr);
  }

  void setCpu(String? text) {
    cpuSummary ??= _nonEmpty(text);
  }

  void setMem(String? text) {
    memSummary ??= _nonEmpty(text);
  }

  void setGfx(String? text) {
    gfxSummary ??= _nonEmpty(text);
  }

  BugreportParseResult toResult() {
    return BugreportParseResult(
      anrs: List.unmodifiable(anrs),
      cpuSummary: cpuSummary,
      memSummary: memSummary,
      gfxSummary: gfxSummary,
    );
  }
}

String? _nonEmpty(String? text) {
  final trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

class _FileScan {
  String? _section;
  _AnrDraft? _anr;
  _ThreadDraft? _thread;
  final _cpu = StringBuffer();
  final _mem = StringBuffer();
  final _gfx = StringBuffer();
  var _cpuLines = 0;
  var _memLines = 0;
  var _gfxLines = 0;
  var _excerptLines = 0;

  void add(String raw, _MergeSink merged) {
    final line = raw.replaceAll('\r', '');
    final header = _sectionHeader.firstMatch(line);
    if (header != null) {
      _finishAnr(merged);
      _section = header.group(1)!.trim().toUpperCase();
      _maybeSummaryLine(line);
      return;
    }
    _maybeSummaryLine(line);
    _maybeStartAnr(line, merged);
    _maybeThread(line);
    _maybeLock(line);
    _fillAnrFields(line);
    _appendExcerpt(line);
  }

  void flush(_MergeSink merged) {
    _finishAnr(merged);
    merged.setCpu(_cpu.toString());
    merged.setMem(_mem.toString());
    merged.setGfx(_gfx.toString());
  }

  void _maybeSummaryLine(String line) {
    if (_isCpuLine(line) || _sectionLooksLike('CPU')) {
      if (_cpuLines < AnrTraceParser.summaryLineCap) {
        _cpu.writeln(line);
        _cpuLines++;
      }
    }
    if (_isMemLine(line) || _sectionLooksLike('MEMORY')) {
      if (_memLines < AnrTraceParser.summaryLineCap) {
        _mem.writeln(line);
        _memLines++;
      }
    }
    if (_isGfxLine(line) || _sectionLooksLike('GFX')) {
      if (_gfxLines < AnrTraceParser.summaryLineCap) {
        _gfx.writeln(line);
        _gfxLines++;
      }
    }
  }

  bool _sectionLooksLike(String key) {
    final section = _section;
    if (section == null) return false;
    return section.contains(key);
  }

  void _maybeStartAnr(String line, _MergeSink merged) {
    if (_pidHeader.hasMatch(line)) {
      final current = _anr;
      if (current == null || current.threads.isNotEmpty) {
        _finishAnr(merged);
        _anr = _AnrDraft();
        _excerptLines = 0;
      }
      _anr!.timestamp ??= _parseTimestamp(line);
      return;
    }
    if (line.contains('ANR in ')) {
      final current = _anr;
      if (current != null &&
          (current.reason != null ||
              current.subject != null ||
              current.threads.isNotEmpty)) {
        _finishAnr(merged);
      }
      _anr ??= _AnrDraft();
      _excerptLines = 0;
    }
  }

  void _fillAnrFields(String line) {
    final anr = _anr;
    if (anr == null) return;
    final anrIn = _anrIn.firstMatch(line);
    if (anrIn != null) {
      anr.process ??= anrIn.group(1);
      anr.packageName ??= anrIn.group(1);
      anr.timestamp ??= _parseTimestamp(line);
    }
    final cmd = _cmdLine.firstMatch(line);
    if (cmd != null) {
      final cmdName = cmd.group(1)!.trim();
      if (anr.process == null || RegExp(r'^\d+$').hasMatch(anr.process!)) {
        anr.process = cmdName;
      }
      anr.packageName ??= _packageish(cmdName);
    }
    final process = _processLine.firstMatch(line);
    if (process != null) {
      anr.process ??= process.group(1)!.trim();
      anr.packageName ??= _packageish(process.group(1)!.trim());
    }
    final pkg = _packageLine.firstMatch(line);
    if (pkg != null) {
      anr.packageName ??= pkg.group(1)!.trim();
    }
    final subject = _subjectLine.firstMatch(line);
    if (subject != null) {
      anr.subject ??= subject.group(1)!.trim();
    }
    final reason = _reasonLine.firstMatch(line);
    if (reason != null) {
      anr.reason ??= reason.group(1)!.trim();
    }
    anr.timestamp ??= _parseTimestamp(line);
  }

  void _maybeThread(String line) {
    final header = _threadHeader.firstMatch(line);
    if (header != null) {
      _closeThread();
      _anr ??= _AnrDraft();
      if (_anr!.threads.length >= AnrTraceParser.maxThreads) {
        _thread = null;
        return;
      }
      final name = header.group(1)!;
      _thread = _ThreadDraft(
        name: name,
        state: header.group(2) ?? '',
        isMain: name == 'main' || name == 'Main',
      );
      return;
    }
    final thread = _thread;
    if (thread == null) return;
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('at ') ||
        trimmed.startsWith('native: ') ||
        trimmed.startsWith('#') ||
        trimmed.startsWith('- ')) {
      if (thread.frames.length < AnrTraceParser.maxFrames) {
        thread.frames.add(trimmed);
      }
    }
  }

  void _maybeLock(String line) {
    final anr = _anr;
    if (anr == null) return;
    final lower = line.toLowerCase();
    if (lower.contains('waiting to lock') ||
        lower.contains('waiting on <') ||
        lower.contains('held by') ||
        lower.contains('- locked <') ||
        lower.contains('deadlock')) {
      if (anr.locked.length < AnrTraceParser.maxLocked) {
        anr.locked.add(line.trim());
      }
    }
  }

  void _appendExcerpt(String line) {
    final anr = _anr;
    if (anr == null) return;
    if (anr.excerpt.length >= AnrTraceParser.excerptCap) return;
    if (_excerptLines > 80 && _thread == null) return;
    anr.excerpt.writeln(line);
    _excerptLines++;
  }

  void _closeThread() {
    final thread = _thread;
    _thread = null;
    if (thread == null) return;
    _anr?.threads.add(thread.toDump());
  }

  void _finishAnr(_MergeSink merged) {
    _closeThread();
    final anr = _anr;
    _anr = null;
    _excerptLines = 0;
    if (anr != null) merged.addAnr(anr.toTrace());
  }
}

class _AnrDraft {
  String? process;
  String? packageName;
  String? subject;
  String? reason;
  DateTime? timestamp;
  final threads = <ThreadDump>[];
  final locked = <String>[];
  final excerpt = StringBuffer();

  AnrTrace toTrace() {
    var raw = excerpt.toString();
    if (raw.length > AnrTraceParser.excerptCap) {
      raw = raw.substring(0, AnrTraceParser.excerptCap);
    }
    return AnrTrace(
      process: process,
      packageName: packageName ?? _packageish(process),
      subject: subject,
      reason: reason ?? subject,
      timestamp: timestamp,
      threads: List.unmodifiable(threads),
      lockedStacks: List.unmodifiable(locked),
      rawExcerpt: raw,
    );
  }
}

class _ThreadDraft {
  _ThreadDraft({
    required this.name,
    required this.state,
    required this.isMain,
  });

  final String name;
  final String state;
  final bool isMain;
  final frames = <String>[];

  ThreadDump toDump() => ThreadDump(
    name: name,
    state: state,
    stackFrames: List.unmodifiable(frames),
    isMain: isMain,
  );
}

String? _packageish(String? value) {
  if (value == null) return null;
  final first = value.split(RegExp(r'\s+')).first;
  if (RegExp(r'^[a-zA-Z][\w.]+').hasMatch(first)) return first;
  return null;
}

DateTime? _parseTimestamp(String line) {
  final iso = _isoStamp.firstMatch(line);
  if (iso != null) {
    final frac = iso.group(3);
    final stamp = frac == null
        ? '${iso.group(1)}T${iso.group(2)}'
        : '${iso.group(1)}T${iso.group(2)}.${frac.padRight(3, '0').substring(0, 3)}';
    return DateTime.tryParse(stamp);
  }
  return null;
}

bool _isCpuLine(String line) {
  return line.startsWith('Load:') ||
      line.startsWith('CPU usage from') ||
      line.contains('CPU usage from');
}

bool _isMemLine(String line) {
  return line.contains('MEMORY INFO') ||
      line.startsWith('** MEMINFO') ||
      line.startsWith('Total RAM:') ||
      line.contains('TOTAL PSS:');
}

bool _isGfxLine(String line) {
  return line.contains('Graphics info') ||
      line.startsWith('Total frames rendered:') ||
      line.startsWith('Janky frames:');
}

final _sectionHeader = RegExp(r'^------\s+(.+?)\s+------\s*$');
final _pidHeader = RegExp(
  r'^----- pid\s+(\d+)\s+at\s+(.+?)\s+-----',
);
final _anrIn = RegExp(r'ANR in ([a-zA-Z][\w.]+)');
final _cmdLine = RegExp(r'^Cmd line:\s*(.+)$');
final _processLine = RegExp(r'^Process:\s*([a-zA-Z][\w.]+)');
final _packageLine = RegExp(r'^Package:\s*([a-zA-Z][\w.]+)');
final _subjectLine = RegExp(r'^Subject:\s*(.+)$');
final _reasonLine = RegExp(r'^Reason:\s*(.+)$');
final _threadHeader = RegExp(
  r'^"([^"]+)"(?:\s+daemon)?\s+prio=\d+\s+tid=\d+\s+(\S+)',
);
final _isoStamp = RegExp(
  r'(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d+))?',
);
