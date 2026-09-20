import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/logcat/logcat_collapse.dart';
import 'package:diagnostic/core/logcat/logcat_parser.dart';

LogcatLine _gatt(String time, String state) {
  return LogcatParser.parse(
    '09-20 $time  4321  4321 I OneDropP2p: gatt server state=$state status=0',
  );
}

void main() {
  test('collapses consecutive identical tag+message', () {
    final rows = collapseLogcatLines([
      _gatt('20:11:15.944', '2'),
      _gatt('20:11:47.740', '2'),
      _gatt('20:11:48.462', '2'),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.count, 3);
    expect(rows.single.line.message, 'gatt server state=2 status=0');
    expect(rows.single.line.timestamp?.second, 48);
  });

  test('stacks consecutive GATT heartbeats that only differ by state digits', () {
    final rows = collapseLogcatLines([
      _gatt('20:11:15.944', '2'),
      _gatt('20:11:47.740', '0'),
      _gatt('20:11:48.462', '2'),
      _gatt('20:12:20.328', '0'),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.count, 4);
    expect(rows.single.line.message, 'gatt server state=0 status=0');
  });

  test('does not merge different wording on the same tag', () {
    final a = LogcatParser.parse(
      '09-20 20:11:15.944  4321  4321 I OneDrop: send start',
    );
    final b = LogcatParser.parse(
      '09-20 20:11:16.010  4321  4321 I OneDrop: send done',
    );
    final rows = collapseLogcatLines([a, b, a]);
    expect(rows, hasLength(3));
  });

  test('merges dump replay of the same body onto the last row', () {
    final rows = collapseLogcatLines([
      _gatt('20:12:21.722', '2'),
      _gatt('20:11:15.944', '2'),
    ]);
    expect(rows, hasLength(1));
    expect(rows.single.count, 2);
  });

  test('keeps different tags as separate rows', () {
    final a = LogcatParser.parse(
      '09-20 20:11:15.944  4321  4321 I OneDropP2p: gatt server state=2 status=0',
    );
    final b = LogcatParser.parse(
      '09-20 20:11:16.000  4321  4321 I OneDrop: send done',
    );
    final rows = collapseLogcatLines([a, b, a]);
    expect(rows, hasLength(3));
  });

  test('export annotates the count', () {
    final rows = collapseLogcatLines([
      _gatt('20:11:15.944', '0'),
      _gatt('20:16:54.006', '0'),
    ]);
    expect(collapsedLogcatExport(rows.single), contains('×2'));
  });
}
