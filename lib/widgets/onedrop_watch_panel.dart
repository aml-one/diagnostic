import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../core/onedrop/onedrop_watch.dart';
import 'desktop_chrome.dart';

/// Compact OneDrop summary above live logcat while USB Watch is on that app.
class OneDropWatchPanel extends StatelessWidget {
  const OneDropWatchPanel({super.key, required this.snapshot});

  final OneDropWatchSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final fail = snapshot.fail;
    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      tint: fail != null ? AmlTheme.pink : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.water_drop_rounded,
                size: 16,
                color: AmlTheme.sky,
              ),
              const SizedBox(width: 8),
              Text(
                'OneDrop',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(width: 8),
              DesktopTag(
                label: snapshot.peers.isEmpty
                    ? 'no nearby'
                    : '${snapshot.peers.length} nearby',
                color: snapshot.peers.isEmpty ? muted : AmlTheme.mint,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Row(label: 'Nearby', value: _nearbyText(snapshot), ink: ink, muted: muted),
          const SizedBox(height: 4),
          _Row(label: 'This phone', value: snapshot.phone, ink: ink, muted: muted),
          const SizedBox(height: 4),
          _Row(label: 'Transfer', value: snapshot.transfer, ink: ink, muted: muted),
          if (fail != null) ...[
            const SizedBox(height: 6),
            Text(
              fail,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: AmlTheme.pink,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _nearbyText(OneDropWatchSnapshot snapshot) {
    if (snapshot.peers.isEmpty) {
      return 'None yet — waiting for Wi-Fi or Bluetooth sightings';
    }
    return snapshot.peers
        .map((peer) => '${peer.name} (${peer.via})')
        .join(' · ');
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.ink,
    required this.muted,
  });

  final String label;
  final String value;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
          ),
        ),
      ],
    );
  }
}
