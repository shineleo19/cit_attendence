import 'dart:async';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

class WifiDirectHelper {
  static final FlutterP2pConnection _p2p = FlutterP2pConnection();
  static List<DiscoveredPeers> _cachedPeers = [];
  static StreamSubscription<List<DiscoveredPeers>>? _peerSubscription;

  /// Initialize: Start listening to the stream.
  static Future<void> initialize() async {
    await _peerSubscription?.cancel();
    _peerSubscription = _p2p.streamPeers().listen((peers) {
      _cachedPeers = peers;
    });
  }

  /// Start looking for devices
  static Future<bool> startDiscovery() async {
    // FIX: Handle null by defaulting to false
    return (await _p2p.discover()) ?? false;
  }

  /// Stop looking for devices
  static Future<bool> stopDiscovery() async {
    // FIX: Handle null
    return (await _p2p.stopDiscovery()) ?? false;
  }

  /// Returns the latest list of found devices
  static Future<List<DiscoveredPeers>> getPeers() async {
    if (_cachedPeers.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return _cachedPeers;
  }

  /// Connect to a specific device address
  static Future<bool> connect(String deviceAddress) async {
    // FIX: Handle null
    return (await _p2p.connect(deviceAddress)) ?? false;
  }

  /// Disconnect / Remove Group
  static Future<bool> disconnect() async {
    // FIX: Handle null
    return (await _p2p.removeGroup()) ?? false;
  }

  /// Helper alias for removeGroup
  static Future<bool> removeGroup() async {
    // FIX: Handle null
    return (await _p2p.removeGroup()) ?? false;
  }

  /// For Coordinator: Create a group (become Group Owner)
  static Future<bool> createGroup() async {
    // FIX: Handle null
    return (await _p2p.createGroup()) ?? false;
  }

  /// Get Connection Info
  // FIX: Changed return type from WifiP2PInfo? to WifiP2PGroupInfo?
  static Future<WifiP2PGroupInfo?> getConnectionInfo() async {
    return await _p2p.groupInfo();
  }

}