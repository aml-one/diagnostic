/// Follow-tail for a reverse log ListView (pixels 0 = live edge).
///
/// Any **finger** drag that leaves the live edge pauses. Direction does not
/// matter (scroll-up vs scroll-down). Layout jumps from new lines have no
/// drag details and must not freeze Live.
abstract final class WatchFollow {
  static const pinPixels = 8.0;

  static bool shouldPause({
    required double pixels,
    required bool userDrag,
  }) =>
      userDrag && pixels > 2;

  static bool shouldResume({
    required double pixels,
    required bool following,
  }) =>
      !following && pixels <= pinPixels;
}
