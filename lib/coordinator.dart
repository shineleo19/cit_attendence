// lib/coordinator.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'db_helper.dart';
import 'weekly_report.dart';
import 'package:printing/printing.dart';
import 'wifi_direct_helper.dart';

class CoordinatorHomePage extends StatefulWidget {
  final String username;
  const CoordinatorHomePage({super.key, required this.username});

  @override
  State<CoordinatorHomePage> createState() => _CoordinatorHomePageState();
}

class _CoordinatorHomePageState extends State<CoordinatorHomePage> {
  // server/socket
  ServerSocket? _server;
  bool sessionActive = false;
  String serverIp = 'Not started';
  final int serverPort = 4040;
  int receivedBatches = 0;
  int receivedRecordsTotal = 0;
  DateTime? lastReceivedAt;
  final List<String> _recentLogs = [];

  final df = DateFormat('yyyy-MM-dd');
  String date = DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }

  void _log(String message) {
    final t = DateFormat('HH:mm:ss').format(DateTime.now());
    _recentLogs.insert(0, '[$t] $message');
    if (_recentLogs.length > 80) _recentLogs.removeLast();
    if (mounted) setState(() {});
  }

  Future<void> _startServer() async {
    if (_server != null) return; // Already running

    try {
      // Start a TCP server on port 4040
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 4040);
      _log('Server started on ${_server!.address.address}:4040');

      _server!.listen((Socket client) {
        // FIXED: Added .cast<List<int>>() for type safety
        client.cast<List<int>>().transform(utf8.decoder).listen((payload) async {
          try {
            final processed = await _processAttendancePayloadFromString(payload);
            receivedBatches += 1;
            receivedRecordsTotal += processed;
            lastReceivedAt = DateTime.now();
            _log('Processed batch: $processed records (total: $receivedRecordsTotal)');

            if (mounted) setState(() {});
          } catch (e, st) {
            _log('Payload processing error: $e');
            debugPrint('Payload parsing error: $e\n$st');
          }
        }, onError: (e, st) {
          _log('Client stream error: $e');
          debugPrint('Client stream error: $e\n$st');
        });
      }, onError: (e, st) {
        _log('Server socket error: $e');
        debugPrint('Server socket error: $e\n$st');
      });

      // Determine display IP (best-effort)
      serverIp = await _getLocalIpForDisplay();
      sessionActive = true;
      _log('Server ready for connections at $serverIp:4040');
      setState(() {});
    } catch (e) {
      _log('Failed to start server: $e');
      debugPrint('Start server error: $e');
      await _stopServer();
    }
  }

  Future<void> _stopServer() async {
    try {
      // FIXED: Used .close() instead of .stop()
      await _server?.close();
    } catch (e) {
      debugPrint('Error stopping server: $e');
    }
    _server = null;
    sessionActive = false;
    serverIp = 'Not started';
    setState(() {});
    _log('Server stopped');
  }

  Future<String> _getLocalIpForDisplay() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false
      );

      // PRIORITY 1: Look for Wi-Fi Direct interface (usually named 'p2p-...')
      for (final iface in interfaces) {
        if (iface.name.toLowerCase().contains('p2p')) {
          for (final addr in iface.addresses) {
            return addr.address; // Return the P2P IP immediately
          }
        }
      }

      // PRIORITY 2: Look for Hotspot interface (usually 'wlan' or 'ap')
      for (final iface in interfaces) {
        if (iface.name.toLowerCase().contains('wlan') || iface.name.toLowerCase().contains('ap')) {
          for (final addr in iface.addresses) {
            if (_isPrivateIp(addr.address)) return addr.address;
          }
        }
      }

      // FALLBACK: Existing logic
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (_isPrivateIp(ip)) return ip;
        }
      }
      return InternetAddress.loopbackIPv4.address;
    } catch (_) {
      return InternetAddress.loopbackIPv4.address;
    }
  }

  bool _isPrivateIp(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    final parts = ip.split('.');
    if (parts.length == 4) {
      final first = int.tryParse(parts[0]) ?? 0;
      final second = int.tryParse(parts[1]) ?? 0;
      if (first == 172 && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  /// Process raw JSON string payload from advisors
  Future<int> _processAttendancePayloadFromString(String payload) async {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      return await _processAttendancePayloadMap(decoded);
    } else {
      _log('Invalid JSON payload (not an object)');
      return 0;
    }
  }

  Future<int> _processAttendancePayloadMap(Map<String, dynamic> map) async {
    try {
      // Accept payloads with or without type
      if (map.containsKey('type') && map['type'] != 'ATT_DATA') {
        _log('Ignored payload: type=${map['type']}');
        return 0;
      }

      final sectionCode = (map['Section'] ?? map['section'] ?? '') as String;
      final dateStr = (map['Date'] ?? map['date']) as String?;
      final slotStr = (map['Slot'] ?? map['slot']) as String? ?? 'FN';
      final recordsRaw = map['Records'] ?? map['records'];

      if (sectionCode.isEmpty) {
        _log('Payload missing Section');
        return 0;
      }
      if (dateStr == null || dateStr.isEmpty) {
        _log('Payload missing Date');
        return 0;
      }
      if (recordsRaw == null || recordsRaw is! List) {
        _log('Payload missing Records array');
        return 0;
      }

      final localStudents = await DBHelper().getStudentsBySectionCode(sectionCode);
      final Map<String, String> regToLocalId = {};
      for (var s in localStudents) {
        final reg = s['reg_no'] as String?;
        final id = s['id'] as String?;
        if (reg != null && id != null) regToLocalId[reg] = id;
      }

      int processed = 0;
      for (final dynamic r in recordsRaw) {
        if (r is! Map<String, dynamic>) continue;

        final incomingReg = (r['RegNo'] ?? r['reg_no'] ?? r['Regno'] ?? r['regNo']) as String?;
        final incomingStudentId = (r['StudentID'] ?? r['studentId'] ?? r['student_id']) as String?;
        String? studentIdToUse;
        if (incomingReg != null && regToLocalId.containsKey(incomingReg)) {
          studentIdToUse = regToLocalId[incomingReg];
        } else if (incomingStudentId != null && incomingStudentId.isNotEmpty) {
          studentIdToUse = incomingStudentId;
        } else {
          // skip unknown record
          continue;
        }

        final status = (r['Status'] ?? r['status']) as String? ?? 'Present';
        final odStatus = (r['ODStatus'] ?? r['od_status'] ?? 'Normal') as String;
        final timeRaw = (r['Time'] ?? r['time']) as String? ?? DateTime.now().toIso8601String();

        // Use DBHelper.upsertAttendance
        await DBHelper().upsertAttendance(
          studentId: studentIdToUse ?? "", // FIXED: Added null check fallback
          sectionCode: sectionCode,
          date: dateStr,
          slot: slotStr,
          status: status,
          odStatus: odStatus,
          time: timeRaw,
          source: 'p2p',
        );

        processed += 1;
      }

      return processed;
    } catch (e, st) {
      debugPrint('Error processing payload: $e\n$st');
      _log('Error processing payload: $e');
      return 0;
    }
  }

  // UI / navigation helpers
  void _openSection(String code) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CoordinatorSectionDetailPage(sectionCode: code, date: date),
    ));
  }

  List<DateTime> _computeWeekRange(String isoDate) {
    final dt = DateTime.parse(isoDate);
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    final dates = <DateTime>[];
    for (int i = 0; i < 6; i++) dates.add(monday.add(Duration(days: i)));
    return dates;
  }

  Future<void> _generateAllSectionsWeeklyPdf() async {
    try { await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx'); } catch (e) {}
    try { await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx'); } catch (e) {}

    final weekDates = _computeWeekRange(date);
    final start = DateFormat('yyyy-MM-dd').format(weekDates.first);
    final end = DateFormat('yyyy-MM-dd').format(weekDates.last);
    final raw = await DBHelper().getStudentAttendanceBetween(start, end);

    final Map<String, Map<String, dynamic>> studentMap = {};
    for (final r in raw) {
      final sid = r['student_id'] as String;
      if (!studentMap.containsKey(sid)) {
        studentMap[sid] = {
          'student_id': sid,
          'reg_no': r['reg_no'] ?? '',
          'name': r['name'] ?? '',
          'section_code': r['section_code'] ?? '',
          'daily': <String, String>{},
        };
      }
      final dateKey = r['date'] as String?;
      final status = r['status'] as String?;
      if (dateKey != null && status != null) {
        (studentMap[sid]!['daily'] as Map<String, String>)[dateKey] = status;
      }
    }

    final rows = studentMap.values.toList()
      ..sort((a, b) {
        final sa = a['section_code'] as String;
        final sb = b['section_code'] as String;
        if (sa != sb) return sa.compareTo(sb);
        return (a['reg_no'] as String).compareTo(b['reg_no'] as String);
      });

    final pdfBytes = await WeeklyReport.generateAll(weekDates: weekDates, rows: rows);
    final filename = 'weekly_report_all_${DateFormat('yyyyMMdd').format(weekDates.first)}_${DateFormat('yyyyMMdd').format(weekDates.last)}.pdf';
    await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: filename);

    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Weekly PDF generated')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Coordinator')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text('Date: $date')),
                ElevatedButton(
                  onPressed: sessionActive ? _stopServer : _startServer,
                  child: Text(sessionActive ? 'Stop Session' : 'Start Session'),
                ),
                const SizedBox(width: 12),
                Text('Batches: $receivedBatches'),
                const SizedBox(width: 12),
                Text('Records: $receivedRecordsTotal'),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                ElevatedButton.icon(
                  onPressed: _generateAllSectionsWeeklyPdf,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download Weekly Report (All Sections)'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48), backgroundColor: Colors.green, foregroundColor: Colors.white),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => CumulativeReportPage(date: date),
                    ));
                  },
                  icon: const Icon(Icons.assessment),
                  label: const Text('CUMULATIVE REPORT'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48), backgroundColor: Colors.orange, foregroundColor: Colors.white),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: DBHelper().getSections(),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final sections = snap.data!;
                if (sections.isEmpty) return const Center(child: Text('No sections available'));
                return ListView.separated(
                  itemCount: sections.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = sections[i];
                    return ListTile(
                      title: Text("CSE-${s['code']}"),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openSection(s['code'] as String),
                    );
                  },
                );
              },
            ),
          ),

          // Server info & logs
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey.withOpacity(0.04),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Server: ${sessionActive ? '$serverIp:$serverPort' : 'Not running'}'),
                if (lastReceivedAt != null) Text('Last received: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(lastReceivedAt!)}'),
                const SizedBox(height: 8),
                const Text('Recent log:'),
                const SizedBox(height: 6),
                Container(
                  height: 120,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.withOpacity(0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _recentLogs.isEmpty
                      ? const Text('No logs yet')
                      : ListView.builder(itemCount: _recentLogs.length, itemBuilder: (context, idx) => Text(_recentLogs[idx], style: const TextStyle(fontSize: 12))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CumulativeReportPage extends StatefulWidget {
  final String date;
  const CumulativeReportPage({super.key, required this.date});

  @override
  State<CumulativeReportPage> createState() => _CumulativeReportPageState();
}

class _CumulativeReportPageState extends State<CumulativeReportPage> {
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic> summary = {
    'total': 0,
    'present': 0,
    'absent': 0,
    'od': 0,
    'percent': 0.0,
    'sectionBreakdown': {}
  };
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _initPage();
  }

  Future<void> _initPage() async {
    await _prepareCoordinatorData();
    await _load();
  }

  Future<void> _load() async {
    setState(() => isLoading = true);
    try {
      final r = await DBHelper().getCumulativeAttendanceByDate(widget.date);
      final s = await DBHelper().getCumulativeSummary(widget.date);
      if (mounted) {
        setState(() {
          rows = r;
          summary = s;
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading cumulative data: $e");
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _prepareCoordinatorData() async {
    try {
      final sections = await DBHelper().getSections();
      if (sections.isEmpty) {
        try {
          await DBHelper()
              .importStudentsFromAsset('assets/data/students_master.xlsx');
        } catch (e) {}
        try {
          await DBHelper()
              .importStudentsFromExcel('/mnt/data/students_master.xlsx');
        } catch (e) {}
      }
    } catch (e) {
      debugPrint("Coordinator import failed: $e");
    }
  }

  String _getDisplayStatus(Map<String, dynamic> record) {
    final status = record['status'] as String? ?? 'Present';
    final odStatus = record['od_status'] as String? ?? 'Normal';
    if (status == 'Absent') return 'Absent';
    if (odStatus == 'OD') return 'OD';
    return 'Present';
  }

  @override
  Widget build(BuildContext context) {
    final sectionBreakdown =
        summary['sectionBreakdown'] as Map<String, Map<String, int>>? ?? {};

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Cumulative Report'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        child: Column(
          children: [
            _buildSummaryCard(),
            if (sectionBreakdown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Section Breakdown",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    ...sectionBreakdown.entries.map((entry) {
                      return _buildSectionRow(entry.key, entry.value);
                    }),
                  ],
                ),
              ),
            const Divider(height: 32),
            const Text("All Records",
                style: TextStyle(color: Colors.grey)),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _buildStudentRow(rows[i]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Colors.orangeAccent, Colors.deepOrange]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        children: [
          const Text(
            "Overall Attendance",
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _statItem("Total", "${summary['total']}"),
              _statItem("Present", "${summary['present']}"),
              _statItem("Absent", "${summary['absent']}"),
              _statItem("OD", "${summary['od']}"),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(20)),
            child: Text(
              "${(summary['percent'] as double).toStringAsFixed(1)}%",
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 22),
            ),
          )
        ],
      ),
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _buildSectionRow(String code, Map<String, int> data) {
    final sectionPercent = data['total']! == 0
        ? 0.0
        : (data['present']! * 100.0 / data['total']!);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text("SEC $code",
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text("P: ${data['present']}",
              style: const TextStyle(color: Colors.green)),
          Text("A: ${data['absent']}",
              style: const TextStyle(color: Colors.red)),
          Text("${sectionPercent.toStringAsFixed(1)}%",
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildStudentRow(Map<String, dynamic> r) {
    final status = _getDisplayStatus(r);
    Color color = Colors.green;
    if (status == 'Absent') color = Colors.red;
    if (status == 'OD') color = Colors.blue;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Text(r['section_code'],
              style: TextStyle(color: color, fontSize: 12)),
        ),
        title: Text(r['name'] ?? '',
            style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: Text(r['reg_no'] ?? ''),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Text(
            status.toUpperCase(),
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

class CoordinatorSectionDetailPage extends StatefulWidget {
  final String sectionCode;
  final String date;
  const CoordinatorSectionDetailPage(
      {super.key, required this.sectionCode, required this.date});

  @override
  State<CoordinatorSectionDetailPage> createState() =>
      _CoordinatorSectionDetailPageState();
}

class _CoordinatorSectionDetailPageState
    extends State<CoordinatorSectionDetailPage> {
  // FIXED: Declared _server variable here
  ServerSocket? _server;

  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic> summary = {
    'total': 0,
    'present': 0,
    'absent': 0,
    'od': 0,
    'percent': 0.0
  };
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _initWifiDirect();
  }

  @override
  void dispose() {
    // FIXED: Close server when leaving page
    _server?.close();
    super.dispose();
  }

  Future<void> _startServer() async {
    try {
      // 0 uses any available port, or specify a port like 4040
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 4040);

      _server?.listen((Socket client) {
        // FIXED: Replaced undefined 'handleClient' with proper listener logic
        client.cast<List<int>>().transform(utf8.decoder).listen((payload) {
          debugPrint("Payload received in section view: $payload");
          // Add processing logic here if needed, or rely on Home Page server
        });
      });

      setState(() {
        // Update UI to show server is running
      });
    } catch (e) {
      print("Error starting server: $e");
    }
  }

  Future<void> _initWifiDirect() async {
    // Ensure WifiDirectHelper is defined in your imports
    await WifiDirectHelper.createGroup();      // phone becomes GO
    await WifiDirectHelper.startDiscovery();   // optional – lets advisors see it
    await _startServer();                // your existing socket server
  }

  Future<void> _load() async {
    setState(() => isLoading = true);
    final r = await DBHelper()
        .getAttendanceForSectionByDate(widget.sectionCode, widget.date);
    final s =
    await DBHelper().getSectionSummary(widget.sectionCode, widget.date);
    if (mounted) {
      setState(() {
        rows = r;
        summary = s;
        isLoading = false;
      });
    }
  }

  List<DateTime> _computeWeekRange(String isoDate) {
    final dt = DateTime.parse(isoDate);
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    final dates = <DateTime>[];
    for (int i = 0; i < 6; i++) {
      dates.add(monday.add(Duration(days: i)));
    }
    return dates;
  }

  Future<void> _generateWeeklyReport() async {
    try {
      await DBHelper()
          .importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {}
    try {
      await DBHelper()
          .importStudentsFromExcel('/mnt/data/students_master.xlsx');
    } catch (e) {}

    final weekDates = _computeWeekRange(widget.date);
    final start = DateFormat('yyyy-MM-dd').format(weekDates.first);
    final end = DateFormat('yyyy-MM-dd').format(weekDates.last);

    final raw = await DBHelper().getStudentAttendanceBetween(start, end);

    final Map<String, Map<String, dynamic>> studentMap = {};
    for (final r in raw) {
      if ((r['section_code'] as String?) != widget.sectionCode) continue;

      final sid = r['student_id'] as String;
      if (!studentMap.containsKey(sid)) {
        studentMap[sid] = {
          'student_id': sid,
          'reg_no': r['reg_no'] ?? '',
          'name': r['name'] ?? '',
          'section_code': r['section_code'] ?? '',
          'daily': <String, String>{},
        };
      }
      final dateKey = r['date'] as String?;
      final status = r['status'] as String?;
      if (dateKey != null && status != null) {
        String shortStatus;
        if (status == 'Present')
          shortStatus = 'P';
        else if (status == 'Absent')
          shortStatus = 'A';
        else if (status == 'OD')
          shortStatus = 'OD';
        else
          shortStatus = '-';
        (studentMap[sid]!['daily'] as Map<String, String>)[dateKey] =
            shortStatus;
      }
    }

    final students = studentMap.values.toList()
      ..sort(
              (a, b) => (a['reg_no'] as String).compareTo(b['reg_no'] as String));

    final pdfBytes = await WeeklyReport.generateForSection(
      sectionCode: widget.sectionCode,
      weekDates: weekDates,
      students: students,
    );

    final filename =
        'weekly_report_${widget.sectionCode}_${DateFormat('yyyyMMdd').format(weekDates.first)}.pdf';
    await Printing.layoutPdf(
        onLayout: (format) async => pdfBytes, name: filename);
  }

  String _getDisplayStatus(Map<String, dynamic> record) {
    final status = record['status'] as String? ?? 'Present';
    final odStatus = record['od_status'] as String? ?? 'Normal';
    if (status == 'Absent') return 'Absent';
    if (odStatus == 'OD') return 'OD';
    return 'Present';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text('Section ${widget.sectionCode}'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: "Download Weekly Report",
            onPressed: _generateWeeklyReport,
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          _buildSummaryHeader(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = rows[i];
                final status = _getDisplayStatus(r);
                Color color = Colors.green;
                if (status == 'Absent') color = Colors.red;
                if (status == 'OD') color = Colors.blue;

                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    title: Text(r['name'] ?? '',
                        style:
                        const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(r['reg_no'] ?? ''),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: color.withOpacity(0.5)),
                      ),
                      child: Text(
                        status.toUpperCase(),
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 11),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.indigo,
        boxShadow: [
          BoxShadow(
              color: Colors.indigo.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 5))
        ],
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statCol("Total", "${summary['total']}"),
          _statCol("Present", "${summary['present']}"),
          _statCol("Absent", "${summary['absent']}"),
          _statCol("OD", "${summary['od']}"),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(12)),
            child: Text(
              "${(summary['percent'] as double).toStringAsFixed(1)}%",
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
          )
        ],
      ),
    );
  }

  Widget _statCol(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18)),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}