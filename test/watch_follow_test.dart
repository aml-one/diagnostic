import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/mobile/watch_follow.dart';

void main() {
  test('pauses on a finger drag away from the live edge', () {
    expect(
      WatchFollow.shouldPause(pixels: 12, userDrag: true),
      isTrue,
    );
    expect(
      WatchFollow.shouldPause(pixels: 3, userDrag: true),
      isTrue,
    );
  });

  test('ignores layout jitter and live-edge noise', () {
    expect(
      WatchFollow.shouldPause(pixels: 0.4, userDrag: true),
      isFalse,
    );
    expect(
      WatchFollow.shouldPause(pixels: 40, userDrag: false),
      isFalse,
    );
  });

  test('resumes only after returning to the live edge', () {
    expect(
      WatchFollow.shouldResume(pixels: 40, following: false),
      isFalse,
    );
    expect(
      WatchFollow.shouldResume(pixels: 4, following: false),
      isTrue,
    );
    expect(
      WatchFollow.shouldResume(pixels: 0, following: true),
      isFalse,
    );
  });
}
