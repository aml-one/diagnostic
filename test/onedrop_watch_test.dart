import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/logcat/logcat_parser.dart';
import 'package:diagnostic/core/onedrop/onedrop_watch.dart';

LogcatLine _line(String tag, String message, {String level = 'I'}) {
  return LogcatParser.parse(
    '09-17 09:00:00.000  4321  4321 $level $tag: $message',
  );
}

void main() {
  test('ignores unrelated packages and tags', () {
    expect(isOneDropWatchPackage('one.aml.messageme'), isFalse);
    expect(isOneDropWatchPackage(kOneDropPackageName), isTrue);
    final tracker = OneDropWatchTracker();
    expect(
      tracker.ingest(_line('ActivityManager', 'ANR in one.aml.onedrop')),
      isFalse,
    );
  });

  test('tracks nearby Wi-Fi and Bluetooth peers and losses', () {
    final tracker = OneDropWatchTracker();
    expect(tracker.ingest(_line('OneDrop', 'wifi peer Pixel')), isTrue);
    expect(tracker.ingest(_line('OneDrop', 'ble peer Fold')), isTrue);
    expect(tracker.ingest(_line('OneDrop', 'lost Pixel')), isTrue);
    final snap = tracker.snapshot();
    expect(snap.peers, hasLength(1));
    expect(snap.peers.single.name, 'Fold');
    expect(snap.peers.single.via, 'Bluetooth');
  });

  test('follows send then receive and explains a decline', () {
    final tracker = OneDropWatchTracker();
    tracker.ingest(_line('OneDrop', 'send start to=Pixel via=ble files=2'));
    tracker.ingest(_line('OneDrop', 'send 25% to=Pixel'));
    tracker.ingest(_line('OneDrop', 'send declined by=Pixel'));
    var snap = tracker.snapshot();
    expect(snap.phone, contains('declined'));
    expect(snap.fail, contains('declined'));

    tracker.ingest(_line('OneDrop', 'recv offer from=Fold files=1'));
    tracker.ingest(_line('OneDrop', 'recv start from=Fold files=1'));
    tracker.ingest(_line('OneDrop', 'recv done from=Fold'));
    snap = tracker.snapshot();
    expect(snap.phone, 'Receive finished');
    expect(snap.fail, isNull);
    expect(snap.transfer, contains('from=Fold'));
  });

  test('native BLE permission and location notes become failures', () {
    final tracker = OneDropWatchTracker();
    expect(
      tracker.ingest(
        _line('OneDropP2p', 'start: BLE perms missing', level: 'I'),
      ),
      isTrue,
    );
    expect(tracker.snapshot().phone.toLowerCase(), contains('permission'));
    tracker.ingest(
      _line(
        'OneDropP2p',
        'Location is off — BLE scan is empty on most phones',
        level: 'W',
      ),
    );
    expect(tracker.snapshot().fail, contains('Location is off'));
  });

  test('gatt drop is a Bluetooth-link failure', () {
    final tracker = OneDropWatchTracker();
    tracker.ingest(
      _line('OneDropP2p', 'gatt dropped status=8 try=1', level: 'W'),
    );
    expect(tracker.snapshot().fail, contains('Bluetooth link dropped'));
  });

  test('Diagnose findings put send fail above nearby', () {
    final findings = oneDropDiagnosisFindings([
      _line('OneDrop', 'wifi peer Pixel'),
      _line('OneDrop', 'send start to=Pixel via=ble files=1'),
      _line('OneDrop', 'send fail to=Pixel reason=timeout'),
    ]);
    expect(findings.first, contains('Send failed'));
    expect(findings, contains('OneDrop: Send failed'));
    expect(findings.any((f) => f.startsWith('Nearby: Pixel')), isTrue);
  });

  test('Diagnose findings explain an empty capture', () {
    expect(
      oneDropDiagnosisFindings([_line('ActivityManager', 'ANR in foo')]).first,
      contains('No OneDrop nearby or send lines'),
    );
  });
}
