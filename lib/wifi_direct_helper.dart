import 'dart:async';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

class WifiDirectHelper {
  static final FlutterP2pConnection _p2p = FlutterP2pConnection();
  static List<DiscoveredPeers> _cachedPeers = [];
  static StreamSubscription<List<DiscoveredPeers>>? _peerSubscription;

  /// REQUIRED: Initialize the plugin so Android WifiManager is ready.
  static Future<void> initialize() async {
    // 1. Initialize the native plugin (Fixes the lateinit property error)
    await _p2p.initialize();

    // 2. Register callbacks (Required for v1.0.3 events)
    await _p2p.register();

    // 3. Start listening to the stream
    _peerSubscription?.cancel();
    _peerSubscription = _p2p.streamPeers().listen((peers) {
      _cachedPeers = peers;
    });
  }

  static Future<bool> startDiscovery() async {
    return (await _p2p.discover()) ?? false;
  }

  static Future<bool> stopDiscovery() async {
    return (await _p2p.stopDiscovery()) ?? false;
  }

  static Future<List<DiscoveredPeers>> getPeers() async {
    if (_cachedPeers.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return _cachedPeers;
  }

  static Future<bool> connect(String deviceAddress) async {
    return (await _p2p.connect(deviceAddress)) ?? false;
  }

  static Future<bool> disconnect() async {
    return (await _p2p.removeGroup()) ?? false;
  }

  static Future<bool> removeGroup() async {
    return (await _p2p.removeGroup()) ?? false;
  }

  static Future<bool> createGroup() async {
    return (await _p2p.createGroup()) ?? false;
  }

  static Future<WifiP2PGroupInfo?> getConnectionInfo() async {
    return await _p2p.groupInfo();
  }
}