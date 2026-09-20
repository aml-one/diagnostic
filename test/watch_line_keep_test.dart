import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/logcat/logcat_parser.dart';
import 'package:diagnostic/core/logcat/watch_line_keep.dart';
import 'package:diagnostic/core/onedrop/onedrop_watch.dart';

LogcatLine _parse(String raw) => LogcatParser.parse(raw);

void main() {
  const keepArgs = (
    pids: <int>{},
    packageName: kOneDropPackageName,
    levelsKey: 'VDIWEF',
    hideSpam: true,
  );

  test('keeps OneDrop native tags when pidof is empty', () {
    const raw =
        '09-20 19:56:01.100  4321  4321 I OneDropP2p: advertise connectable=true session=1 bytes=24';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: keepArgs.pids,
        packageName: keepArgs.packageName,
        levelsKey: keepArgs.levelsKey,
        hideSpam: keepArgs.hideSpam,
      ),
      isTrue,
    );
  });

  test('drops launcher IconCustomizer that only mentions the package', () {
    const raw =
        '09-20 19:56:01.541  2100  2100 I IconCustomizer: find better bitmap : 144px, for one.aml.onedropat density : 480dpi';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: keepArgs.pids,
        packageName: keepArgs.packageName,
        levelsKey: keepArgs.levelsKey,
        hideSpam: keepArgs.hideSpam,
      ),
      isFalse,
    );
    expect(isLogcatDisplayNoise(_parse(raw)), isTrue);
  });

  test('does not treat package-name substring as the app', () {
    const raw =
        '09-20 19:56:01.542  2100  2100 D IconCustomizer: Generate customized icon for one.aml.onedrop.png, false';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: keepArgs.pids,
        packageName: keepArgs.packageName,
        levelsKey: keepArgs.levelsKey,
        hideSpam: keepArgs.hideSpam,
      ),
      isFalse,
    );
  });

  test('keeps flutter OneDrop tag lines', () {
    const raw =
        '09-20 19:56:02.000  4321  4321 I OneDrop: radio start ok';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: keepArgs.pids,
        packageName: keepArgs.packageName,
        levelsKey: keepArgs.levelsKey,
        hideSpam: keepArgs.hideSpam,
      ),
      isTrue,
    );
  });

  test('keeps send-done when Watch pid is a newer OneDrop process', () {
    const raw =
        '09-20 19:56:03.000  4321  4321 I OneDrop: send done to=Anita';
    final line = _parse(raw);
    expect(
      shouldKeepWatchLine(
        line,
        pids: {9999},
        packageName: kOneDropPackageName,
        levelsKey: keepArgs.levelsKey,
        hideSpam: keepArgs.hideSpam,
      ),
      isTrue,
    );
    expect(isOneDropWatchLine(line), isTrue);
    final gate = LogcatPidGate(9999);
    expect(gate.accept(line), isFalse);
  });

  test('keeps another app flutter line when uid-scoped even if pidof is empty', () {
    const raw =
        '09-20 19:56:04.000  5555  5555 I flutter: MessageMe started';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: {},
        packageName: 'one.aml.messageme',
        levelsKey: 'VDIWEF',
        hideSpam: true,
        uidScoped: true,
      ),
      isTrue,
    );
  });

  test('keeps OneDrop BluetoothGatt lines', () {
    const raw =
        '09-20 19:56:05.000  210  210 I BluetoothGatt: onClientConnectionState status=0';
    expect(
      shouldKeepWatchLine(
        _parse(raw),
        pids: {},
        packageName: kOneDropPackageName,
        levelsKey: 'VDIWEF',
        hideSpam: true,
      ),
      isTrue,
    );
  });
}
