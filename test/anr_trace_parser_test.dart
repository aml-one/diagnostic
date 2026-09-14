import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:diagnostic/core/bugreport/anr_trace_parser.dart';
import 'package:diagnostic/core/bugreport/bugreport_service.dart';
import 'package:diagnostic/core/perf/dumpsys_snapshot.dart';

void main() {
  late String fixturePath;

  setUpAll(() {
    fixturePath = p.join('test', 'fixtures', 'anr_dumpstate.txt');
  });

  test('parses ANR dumpstate fixture', () async {
    final text = await File(fixturePath).readAsString();
    final result = AnrTraceParser.parseText(text);

    expect(result.anrs, isNotEmpty);
    final anr = result.preferredAnr('one.aml.messageme');
    expect(anr, isNotNull);
    expect(anr!.packageName, 'one.aml.messageme');
    expect(anr.process, anyOf('one.aml.messageme', '4321'));
    expect(anr.reason, contains('Input dispatching timed out'));
    expect(anr.subject, contains('Input dispatching timed out'));
    expect(anr.timestamp, isNotNull);
    expect(anr.timestamp!.year, 2026);
    expect(anr.timestamp!.month, 9);
    expect(anr.timestamp!.day, 14);

    expect(anr.threads, isNotEmpty);
    final main = anr.threads.firstWhere((t) => t.isMain);
    expect(main.name, 'main');
    expect(main.state, 'Native');
    expect(main.stackFrames, isNotEmpty);
    expect(
      main.stackFrames.any((f) => f.contains('MessageQueue.nativePollOnce')),
      isTrue,
    );
    expect(anr.lockedStacks, isNotEmpty);
    expect(anr.lockedStacks.any((line) => line.contains('held by tid=12')), isTrue);
    expect(anr.rawExcerpt, isNotEmpty);
    expect(anr.rawExcerpt.length, lessThanOrEqualTo(AnrTraceParser.excerptCap));

    expect(result.cpuSummary, contains('Load: 4.52'));
    expect(result.memSummary, contains('Total RAM:'));
    expect(result.gfxSummary, contains('Janky frames: 42'));
  });

  test('prefers the most recent matching package', () {
    const older = '''
ANR in one.aml.one_auth
Reason: older stall
time=2026-09-14 13:00:00.000
''';
    const newer = '''
ANR in one.aml.messageme
Reason: newer stall
time=2026-09-14 14:06:22.123
''';
    final result = AnrTraceParser.parseText('$older\n------ next ------\n$newer');
    expect(result.anrs.length, greaterThanOrEqualTo(2));
    final preferred = result.preferredAnr('one.aml.messageme');
    expect(preferred?.reason, contains('newer stall'));
    expect(result.preferredAnr()?.reason, contains('newer stall'));
  });

  test('discoverArtifacts finds FS_DUMPSTATE and anr files', () async {
    final root = await Directory.systemTemp.createTemp('diag-br-');
    addTearDown(() => root.delete(recursive: true));
    final anrDir = Directory(p.join(root.path, 'FS', 'data', 'anr'));
    await anrDir.create(recursive: true);
    await File(p.join(anrDir.path, 'anr_2026-09-14')).writeAsString('traces');
    await File(p.join(root.path, 'traces.txt')).writeAsString('----- pid 1 -----');
    await File(p.join(root.path, 'bugreport-test.txt')).writeAsString('dump');
    final fsDump = Directory(p.join(root.path, 'FS_DUMPSTATE'));
    await fsDump.create();
    await File(p.join(fsDump.path, 'dumpstate.txt')).writeAsString('mem');

    final found = await BugreportService.discoverArtifacts(root.path);
    expect(found.fsDumpstateDir, fsDump.path);
    expect(found.dumpstateFiles.any((path) => path.endsWith('bugreport-test.txt')), isTrue);
    expect(found.dumpstateFiles.any((path) => path.endsWith('dumpstate.txt')), isTrue);
    expect(found.anrFiles.any((path) => path.contains('anr_2026-09-14')), isTrue);
    expect(found.anrFiles.any((path) => path.endsWith('traces.txt')), isTrue);
  });

  test('parseGfxInfo meminfo cpuinfo excerpts', () {
    const gfx = '''
** Graphics info for pid 4321 [one.aml.messageme] **
Total frames rendered: 500
Janky frames: 42 (8.40%)
''';
    final gfxSnap = parseGfxInfo(gfx, package: 'one.aml.messageme');
    expect(gfxSnap.totalFrames, 500);
    expect(gfxSnap.jankyFrames, 42);
    expect(gfxSnap.jankyPercent, closeTo(8.40, 0.01));

    const mem = '''
** MEMINFO in pid 4321 [one.aml.messageme] **
App Summary
           Java Heap:    20000
         Native Heap:    30000
           TOTAL PSS:    75000            TOTAL RSS:    80000
''';
    final memSnap = parseMemInfo(mem, package: 'one.aml.messageme');
    expect(memSnap.totalPssKb, 75000);
    expect(memSnap.nativeHeapPssKb, 30000);
    expect(memSnap.dalvikHeapPssKb, 20000);

    const cpu = '''
Load: 4.52 / 3.10 / 2.21
CPU usage from 100ms to 200ms ago:
  48% 4321/one.aml.messageme: 30% user + 18% kernel
  12% 1000/system_server: 8% user + 4% kernel
''';
    final cpuSnap = parseCpuInfo(cpu);
    expect(cpuSnap.load, startsWith('Load:'));
    expect(cpuSnap.top, isNotEmpty);
    expect(cpuSnap.top.first.name, 'one.aml.messageme');
    expect(cpuSnap.top.first.percent, 48);
    expect(cpuSnap.top.first.pid, 4321);
  });
}
