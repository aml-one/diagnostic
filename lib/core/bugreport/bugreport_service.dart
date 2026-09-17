import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../adb/adb_client.dart';

/// Paths from one `adb bugreport` capture plus unzip.
class BugreportResult {
  const BugreportResult({
    required this.zipPath,
    required this.extractDir,
    this.fsDumpstateDir,
    this.dumpstateFiles = const [],
    this.anrFiles = const [],
  });

  final String zipPath;
  final String extractDir;

  /// `FS_DUMPSTATE` folder when the zip included one.
  final String? fsDumpstateDir;

  /// `dumpstate.txt` / `bugreport-*.txt` under [extractDir].
  final List<String> dumpstateFiles;

  /// Files under `FS/data/anr/`, `anr_*`, and `traces.txt`.
  final List<String> anrFiles;
}

/// Pulls `adb bugreport`, unzips with `archive`, and lists dumpstate / ANR files.
class BugreportService {
  BugreportService({
    AdbClient? adb,
    Future<Directory> Function()? resolveWorkRoot,
  }) : _adb = adb ?? AdbClient(),
       _resolveWorkRoot = resolveWorkRoot ?? _defaultWorkRoot;

  final AdbClient _adb;
  final Future<Directory> Function() _resolveWorkRoot;

  Future<BugreportResult> capture({
    required String serial,
    void Function(String status)? onProgress,
    AdbCancelToken? cancel,
  }) async {
    final work = await _prepareWorkDir();
    final zipPath = p.join(work.path, 'bugreport.zip');
    final extractDir = p.join(work.path, 'extracted');

    onProgress?.call('Started bugreport');
    final started = DateTime.now();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (cancel?.isCancelled == true) return;
      onProgress?.call(
        'Running bugreport (${_formatElapsed(DateTime.now().difference(started))})',
      );
    });
    ProcessResult result;
    try {
      result = await _adb.runTracked(
        ['bugreport', zipPath],
        serial: serial,
        cancel: cancel,
      );
    } finally {
      timer.cancel();
    }
    if (cancel?.isCancelled == true) throw const AdbCancelled();

    final resolvedZip = await _resolveZipPath(work, zipPath);
    if (result.exitCode != 0 && resolvedZip == null) {
      final err = result.stderr.toString().trim();
      throw AdbException(
        err.isEmpty ? 'adb bugreport failed' : err,
        exitCode: result.exitCode,
      );
    }
    if (resolvedZip == null) {
      throw AdbException(
        'adb bugreport finished without writing a zip at $zipPath',
        exitCode: result.exitCode,
      );
    }

    onProgress?.call('Unzipping bugreport');
    await Directory(extractDir).create(recursive: true);
    // Bugreports (esp. OEM FS dumps) often contain Linux paths with ':' in
    // filenames — illegal on Windows. extractFileToDisk fails hard on those;
    // use a sanitizing extractor instead.
    await _extractZipSafely(resolvedZip, extractDir);

    final artifacts = await discoverArtifacts(extractDir);
    onProgress?.call('Done');
    return BugreportResult(
      zipPath: resolvedZip,
      extractDir: extractDir,
      fsDumpstateDir: artifacts.fsDumpstateDir,
      dumpstateFiles: artifacts.dumpstateFiles,
      anrFiles: artifacts.anrFiles,
    );
  }

  /// Walk an already-extracted bugreport for dumpstate / ANR / FS_DUMPSTATE.
  static Future<BugreportResult> discoverArtifacts(String extractDir) async {
    String? fsDumpstateDir;
    final dumpstate = <String>[];
    final anr = <String>[];
    final root = Directory(extractDir);
    if (!root.existsSync()) {
      return BugreportResult(
        zipPath: '',
        extractDir: extractDir,
      );
    }
    await _walkDiscover(root, (entity) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        if (name == 'FS_DUMPSTATE' || name.toLowerCase() == 'fs_dumpstate') {
          fsDumpstateDir = entity.path;
        }
        return;
      }
      if (entity is! File) return;
      final name = p.basename(entity.path).toLowerCase();
      final parent = p.basename(p.dirname(entity.path)).toLowerCase();
      final rel = p
          .relative(entity.path, from: extractDir)
          .replaceAll('\\', '/');
      if (_isDumpstateName(name)) {
        dumpstate.add(entity.path);
      }
      if (parent == 'anr' ||
          name.startsWith('anr_') ||
          name == 'traces.txt' ||
          name.startsWith('traces') ||
          rel.contains('/anr/') ||
          rel.contains('FS_DUMPSTATE') ||
          rel.contains('fs_dumpstate')) {
        if (!_isDumpstateName(name) || parent == 'anr') {
          anr.add(entity.path);
        }
      }
    });
    dumpstate.sort();
    anr.sort();
    return BugreportResult(
      zipPath: '',
      extractDir: extractDir,
      fsDumpstateDir: fsDumpstateDir,
      dumpstateFiles: dumpstate,
      anrFiles: anr,
    );
  }

  Future<Directory> _prepareWorkDir() async {
    final base = await _resolveWorkRoot();
    final stamp = _stamp();
    final dir = Directory(p.join(base.path, 'bugreports', stamp));
    await dir.create(recursive: true);
    return dir;
  }
}

Future<Directory> _defaultWorkRoot() async {
  try {
    return await getApplicationSupportDirectory();
  } on Object {
    return Directory.systemTemp;
  }
}

Future<String?> _resolveZipPath(Directory work, String expected) async {
  final exact = File(expected);
  if (await exact.exists() && await exact.length() > 0) return exact.path;
  File? newest;
  var newestStamp = DateTime.fromMillisecondsSinceEpoch(0);
  await for (final entity in work.list(followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.zip')) continue;
    final stat = await entity.stat();
    if (stat.size <= 0) continue;
    if (stat.modified.isAfter(newestStamp)) {
      newestStamp = stat.modified;
      newest = entity;
    }
  }
  return newest?.path;
}

/// Unzip [zipPath] into [extractDir], rewriting any path segment that would be
/// illegal on Windows (`:` `*` `?` `|` `<` `>` `"` and control chars).
///
/// Android / OEM bugreports routinely ship Linux-only names such as
/// `pre_shutdown_log_2026-08-07_13:05:31.427`. Stock [extractFileToDisk]
/// throws `FileSystemException` (errno 123) on those; this path keeps going.
Future<void> _extractZipSafely(String zipPath, String extractDir) async {
  final input = InputFileStream(zipPath);
  late final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } finally {
    await input.close();
  }

  final root = p.normalize(extractDir);
  for (final entry in archive) {
    final safeRel = _sanitizeZipEntryName(entry.name);
    if (safeRel.isEmpty) continue;
    final outPath = p.normalize(p.join(root, safeRel));
    // Zip-slip: refuse anything that would escape [extractDir].
    if (outPath != root && !p.isWithin(root, outPath)) continue;

    if (entry.isSymbolicLink) continue;

    if (entry.isDirectory) {
      await Directory(outPath).create(recursive: true);
      continue;
    }

    await Directory(p.dirname(outPath)).create(recursive: true);
    final output = OutputFileStream(outPath);
    try {
      entry.writeContent(output);
    } catch (_) {
      // Skip corrupt / unreadable members; ANR traces we need are elsewhere.
    }
    await output.close();
  }
}

/// Collapse `a/../b`, strip absolute prefixes, and replace Windows-illegal
/// characters in every path segment with `_`.
String _sanitizeZipEntryName(String name) {
  var n = name.replaceAll('\\', '/');
  while (n.startsWith('/')) {
    n = n.substring(1);
  }
  if (n.isEmpty) return '';
  final parts = <String>[];
  for (final part in n.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') continue;
    parts.add(_sanitizePathSegment(part));
  }
  return parts.join('/');
}

String _sanitizePathSegment(String segment) {
  final buf = StringBuffer();
  for (final unit in segment.codeUnits) {
    final ch = String.fromCharCode(unit);
    if (unit < 32 || r'<>:"/\|?*'.contains(ch)) {
      buf.write('_');
    } else {
      buf.write(ch);
    }
  }
  var s = buf.toString().trim();
  // Windows also rejects trailing dots/spaces in file/dir names.
  while (s.endsWith('.') || s.endsWith(' ')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return '_';
  return s;
}

bool _isDumpstateName(String name) {
  if (!name.endsWith('.txt')) return false;
  return name == 'dumpstate.txt' ||
      name.startsWith('dumpstate') ||
      name.startsWith('bugreport');
}

Future<void> _walkDiscover(
  Directory dir,
  void Function(FileSystemEntity entity) visit,
) async {
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is Directory) {
      final name = p.basename(entity.path).toLowerCase();
      if (name == 'proto' || name == 'camera' || name == 'wifi') continue;
      visit(entity);
      await _walkDiscover(entity, visit);
    } else {
      visit(entity);
    }
  }
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-'
      '${two(n.hour)}${two(n.minute)}${two(n.second)}';
}

String _formatElapsed(Duration elapsed) {
  final total = elapsed.inSeconds;
  if (total < 60) return '${total}s';
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '${minutes}m ${seconds}s';
}
