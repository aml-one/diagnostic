import '../logcat/logcat_parser.dart';

/// One Drop's Android package. Watch uses this to turn on the live panel.
const kOneDropPackageName = 'one.aml.onedrop';

const kOneDropLogTags = {
  'OneDrop',
  'OneDropP2p',
  'OneDropEngine',
};

bool isOneDropWatchPackage(String? packageName) =>
    packageName == kOneDropPackageName;

bool isOneDropWatchLine(LogcatLine line) {
  if (!line.isParsed) return false;
  if (kOneDropLogTags.contains(line.tag)) return true;
  if (line.tag != 'flutter') return false;
  final message = line.message;
  return message.startsWith('[OneDrop]') ||
      message.startsWith('OneDrop:');
}

String oneDropWatchPayload(LogcatLine line) {
  var message = line.message.trim();
  const wrapped = '[OneDrop] ';
  if (message.startsWith(wrapped)) {
    return message.substring(wrapped.length).trim();
  }
  return message;
}

class OneDropWatchPeer {
  const OneDropWatchPeer({required this.name, required this.via});

  final String name;
  final String via;
}

class OneDropWatchSnapshot {
  const OneDropWatchSnapshot({
    required this.peers,
    required this.phone,
    required this.transfer,
    this.fail,
  });

  static const empty = OneDropWatchSnapshot(
    peers: [],
    phone: 'Waiting for OneDrop logs…',
    transfer: 'No transfer yet',
  );

  final List<OneDropWatchPeer> peers;
  final String phone;
  final String transfer;
  final String? fail;
}

/// Parses OneDrop Flutter + native logcat into a compact USB Watch summary.
///
/// Call [ingest] on the adb stream. Do not [setState] per line — read
/// [generation] on the existing Watch tick.
class OneDropWatchTracker {
  final _peers = <String, String>{};
  String _phone = OneDropWatchSnapshot.empty.phone;
  String _transfer = OneDropWatchSnapshot.empty.transfer;
  String? _fail;
  int generation = 0;

  OneDropWatchSnapshot snapshot() {
    final names = _peers.keys.toList()..sort();
    return OneDropWatchSnapshot(
      peers: [
        for (final name in names)
          OneDropWatchPeer(name: name, via: _peers[name]!),
      ],
      phone: _phone,
      transfer: _transfer,
      fail: _fail,
    );
  }

  /// Returns true when the summary changed.
  bool ingest(LogcatLine line) {
    if (!isOneDropWatchLine(line)) return false;
    final before = generation;
    final msg = oneDropWatchPayload(line);
    if (msg.isEmpty) return false;
    final tag = line.tag;
    if (tag == 'OneDropP2p' || tag == 'OneDropEngine') {
      _ingestNative(msg, line.level);
    } else {
      _ingestFlutter(msg, line.level);
    }
    return generation != before;
  }

  void _ingestFlutter(String msg, String level) {
    if (msg.startsWith('wifi peer ')) {
      _setPeer(msg.substring(10).trim(), 'Wi-Fi');
      _setPhone('Saw ${_peers.length} nearby');
      return;
    }
    if (msg.startsWith('ble peer ')) {
      _setPeer(msg.substring(9).trim(), 'Bluetooth');
      _setPhone('Saw ${_peers.length} nearby');
      return;
    }
    if (msg.startsWith('lost ')) {
      for (final raw in msg.substring(5).split(',')) {
        final name = raw.trim();
        if (name.isNotEmpty) _peers.remove(name);
      }
      generation++;
      _setPhone(
        _peers.isEmpty ? 'Nearby list is empty' : 'Saw ${_peers.length} nearby',
      );
      return;
    }
    if (msg.startsWith('send start ')) {
      _setTransfer(_rest(msg, 'send start '));
      _setPhone('Sending');
      _clearFail();
      return;
    }
    if (msg.startsWith('send ') && msg.contains('% to=')) {
      _setTransfer(msg);
      return;
    }
    if (msg.startsWith('send done ')) {
      _setTransfer(_rest(msg, 'send done '));
      _setPhone('Send finished');
      _clearFail();
      return;
    }
    if (msg.startsWith('send cancelled ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Send cancelled');
      return;
    }
    if (msg.startsWith('send declined ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Waiting — other phone declined');
      return;
    }
    if (msg.startsWith('send fail ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Send failed');
      return;
    }
    if (msg.startsWith('recv offer ')) {
      _setTransfer(_rest(msg, 'recv offer '));
      _setPhone('Incoming offer');
      _clearFail();
      return;
    }
    if (msg.startsWith('recv auto-accept ') ||
        msg.startsWith('recv accepted ')) {
      _setTransfer(msg);
      _setPhone('Accepting a drop');
      return;
    }
    if (msg.startsWith('recv declined ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Incoming offer declined or timed out');
      return;
    }
    if (msg.startsWith('recv start ') || msg.startsWith('recv file ')) {
      _setTransfer(_restAfterRecv(msg));
      _setPhone('Receiving');
      _clearFail();
      return;
    }
    if (msg.startsWith('recv done ')) {
      _setTransfer(_rest(msg, 'recv done '));
      _setPhone('Receive finished');
      _clearFail();
      return;
    }
    if (msg.startsWith('recv cancelled ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Receive cancelled');
      return;
    }
    if (msg.startsWith('recv too large ') || msg.startsWith('recv fail ')) {
      _setTransfer(msg);
      _setFail(explainOneDropFailure(msg));
      _setPhone('Receive failed');
      return;
    }
    if (msg.startsWith('ble link ')) {
      _setFail(explainOneDropFailure(msg));
      _setPhone('Bluetooth link failed');
      return;
    }
    if (msg.startsWith('start ')) {
      _setPhone('Nearby is running');
      return;
    }
    if (msg.startsWith('no ipv4')) {
      _setFail(explainOneDropFailure(msg));
      _setPhone('No Wi-Fi address yet');
      return;
    }
    if (msg.startsWith('radio start ok')) {
      _setPhone('Nearby radio is up');
      _clearFail();
      return;
    }
    if (msg.startsWith('radio start ')) {
      _setFail(explainOneDropFailure(msg));
      _setPhone('Nearby radio failed to start');
      return;
    }
    if (msg.startsWith('radio unsupported')) {
      _setPhone('Bluetooth nearby is not on this OS');
      return;
    }
    if (msg.startsWith('start failed')) {
      _setFail(explainOneDropFailure(msg));
      _setPhone('OneDrop failed to start');
      return;
    }
    if (msg.startsWith('radio ') ||
        msg.startsWith('perm ') ||
        msg.startsWith('connect ') ||
        msg.startsWith('scan ') ||
        msg.startsWith('no_ipv4') ||
        msg.startsWith('resume') ||
        msg.startsWith('opt_in') ||
        msg.startsWith('opt_out')) {
      _setPhone(_humanEvent(msg));
      if (_looksFail(msg, level)) {
        _setFail(explainOneDropFailure(msg));
      }
    }
  }

  void _ingestNative(String msg, String level) {
    final low = msg.toLowerCase();
    if (_looksFail(low, level)) {
      _setFail(explainOneDropFailure(msg));
    }
    if (low.contains('perms missing')) {
      _setPhone('Bluetooth permission missing');
      return;
    }
    if (low.contains('location is off')) {
      _setPhone('Location is off — BLE nearby stays empty');
      return;
    }
    if (low.startsWith('linked ')) {
      _setPhone('Private Wi-Fi link is open');
      return;
    }
    if (low.startsWith('connecting ') || low.contains('fresh sighting')) {
      _setPhone('Opening a Bluetooth link');
      return;
    }
    if (low.startsWith('waiting for ')) {
      _setPhone('Waiting to see the other phone');
      return;
    }
    if (low.startsWith('hung gatt') || low.startsWith('timeout gatt')) {
      _setPhone('Bluetooth link is stuck — retrying');
      return;
    }
    if (low.startsWith('gatt dropped')) {
      _setPhone('Bluetooth link dropped');
      return;
    }
    if (low.startsWith('gatt ')) {
      _setPhone('Bluetooth GATT: $msg');
      return;
    }
    if (low.startsWith('ble discovery paused')) {
      _setPhone('Nearby paused for AirGrab camera');
      return;
    }
    if (low.startsWith('ble discovery resumed')) {
      _setPhone('Nearby resumed after AirGrab');
      return;
    }
    if (low.startsWith('radio held')) {
      _setPhone('Nearby radio held for AirGrab');
      return;
    }
    if (low.startsWith('advertise failed')) {
      _setPhone('This phone cannot be seen over BLE');
      return;
    }
    if (low.startsWith('scan failed')) {
      _setPhone('This phone cannot see nearby OneDrop devices');
      return;
    }
    if (low.startsWith('hotspot')) {
      _setPhone('Local hotspot failed');
      return;
    }
    if (tagLooksEngine(msg)) {
      _setPhone(msg);
    }
  }

  bool tagLooksEngine(String msg) =>
      msg.contains('JNI') || msg.startsWith('skip ') || msg.startsWith('cached engine');

  void _setPeer(String name, String via) {
    if (name.isEmpty) return;
    if (_peers[name] == via) return;
    _peers[name] = via;
    generation++;
  }

  void _setPhone(String value) {
    if (value.isEmpty || value == _phone) return;
    _phone = value;
    generation++;
  }

  void _setTransfer(String value) {
    if (value.isEmpty || value == _transfer) return;
    _transfer = value;
    generation++;
  }

  void _setFail(String value) {
    if (value.isEmpty || value == _fail) return;
    _fail = value;
    generation++;
  }

  void _clearFail() {
    if (_fail == null) return;
    _fail = null;
    generation++;
  }
}

String _rest(String msg, String prefix) => msg.substring(prefix.length).trim();

String _restAfterRecv(String msg) {
  const prefixes = ['recv start ', 'recv file '];
  for (final prefix in prefixes) {
    if (msg.startsWith(prefix)) return msg.substring(prefix.length).trim();
  }
  return msg;
}

String _humanEvent(String msg) {
  if (msg.startsWith('perm ')) {
    return 'Permission: ${msg.substring(5)}';
  }
  if (msg.startsWith('connect ')) {
    return 'Connect: ${msg.substring(8)}';
  }
  if (msg.startsWith('radio ')) {
    return 'Radio: ${msg.substring(6)}';
  }
  if (msg.startsWith('scan ')) {
    return 'Scan: ${msg.substring(5)}';
  }
  return msg;
}

bool _looksFail(String msg, String level) {
  if (level == 'E' || level == 'F') return true;
  final low = msg.toLowerCase();
  if (low.contains(' ok') && !low.contains('fail')) return false;
  return low.contains('fail') ||
      low.contains('dropped') ||
      low.contains('hung') ||
      low.contains('timeout') ||
      low.contains('declined') ||
      low.contains('cancelled') ||
      low.contains('missing') ||
      low.contains('too large') ||
      low.contains('location is off') ||
      low.contains('no ipv4') ||
      low.contains('hotspot') ||
      low.contains('unsupported');
}

/// Short reason shown on the Watch panel — never file paths or bytes.
String explainOneDropFailure(String message) {
  final low = message.toLowerCase();
  if (low.contains('location is off')) {
    return 'Location is off — BLE nearby stays empty on most phones.';
  }
  if (low.contains('ble perms missing') || low.contains('perm ')) {
    return 'A Nearby permission is missing — scan cannot start.';
  }
  if (low.contains('advertise failed')) {
    return 'BLE advertising failed — other phones cannot see this one.';
  }
  if (low.contains('scan failed') || low.contains('scan_failed')) {
    return 'BLE scan failed — this phone cannot see nearby OneDrop devices.';
  }
  if (low.contains('gatt dropped')) {
    return 'Bluetooth link dropped before a Wi-Fi path opened.';
  }
  if (low.contains('hung gatt')) {
    return 'Bluetooth GATT hung — retrying the link.';
  }
  if (low.contains('timeout gatt')) {
    return 'Bluetooth connect timed out.';
  }
  if (low.contains('discover_failed')) {
    return 'Bluetooth service discovery failed.';
  }
  if (low.contains('hotspot')) {
    return 'Local hotspot failed — radio send cannot open a private Wi-Fi path.';
  }
  if (low.contains('send declined')) {
    return 'The other phone declined the send.';
  }
  if (low.contains('send cancelled') || low.contains('recv cancelled')) {
    return 'The transfer was cancelled.';
  }
  if (low.contains('recv declined')) {
    return 'Incoming offer was declined or timed out.';
  }
  if (low.contains('too large')) {
    return 'A file was over the OneDrop size limit.';
  }
  if (low.contains('no ipv4')) {
    return 'No Wi-Fi IPv4 — LAN announce is waiting for Wi-Fi.';
  }
  if (low.contains('ble link')) {
    return 'Could not open a Bluetooth path to the other phone.';
  }
  if (low.contains('start failed')) {
    return 'OneDrop failed to start: $message';
  }
  if (low.contains('send fail')) {
    return 'Send failed: ${message.replaceFirst(RegExp(r'^send fail\s+'), '')}';
  }
  if (low.contains('recv fail')) {
    return 'Receive failed: ${message.replaceFirst(RegExp(r'^recv fail\s+'), '')}';
  }
  return message;
}

/// Diagnose headlines from OneDrop Watch tags — fail first, then phone /
/// transfer / nearby. Info-level send lines never show up in error counts.
List<String> oneDropDiagnosisFindings(Iterable<LogcatLine> lines) {
  final tracker = OneDropWatchTracker();
  var saw = false;
  for (final line in lines) {
    if (tracker.ingest(line)) saw = true;
  }
  if (!saw) {
    return const [
      'No OneDrop nearby or send lines in this capture. Open OneDrop, try a send, then Diagnose again.',
    ];
  }
  final snap = tracker.snapshot();
  final out = <String>[];
  final fail = snap.fail;
  if (fail != null && fail.isNotEmpty) out.add(fail);
  out.add('OneDrop: ${snap.phone}');
  out.add('Transfer: ${snap.transfer}');
  if (snap.peers.isEmpty) {
    out.add('Nearby: none — waiting for Wi-Fi or Bluetooth sightings.');
  } else {
    out.add(
      'Nearby: ${snap.peers.map((p) => '${p.name} (${p.via})').join(' · ')}',
    );
  }
  return out;
}
