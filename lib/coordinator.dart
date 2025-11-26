import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'db_helper.dart';
import 'weekly_report.dart';
import 'package:printing/printing.dart';

class CoordinatorHomePage extends StatefulWidget {
  final String username;
  const CoordinatorHomePage({super.key, required this.username});

  @override
  State<CoordinatorHomePage> createState() => _CoordinatorHomePageState();
}

class _CoordinatorHomePageState extends State<CoordinatorHomePage> {
  // HTTP server state
  HttpServer? _server;
  bool sessionActive = false;
  String serverIp = 'Not started';
  final int serverPort = 4040;
  int receivedBatches = 0;
  int receivedRecordsTotal = 0;
  DateTime? lastReceivedAt;
  final List<String> _recentLogs = [];

  // Keep some original state names for compatibility
  bool advertising = false;
  int connectedCount = 0;

  final df = DateFormat('yyyy-MM-dd');
  String date = DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }

  // ---------------------
  // HTTP server helpers
  // ---------------------
  Future<String> _getLocalIpForDisplay() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (_isPrivateIp(ip)) return ip;
        }
      }
      if (interfaces.isNotEmpty) {
        final first = interfaces.first.addresses.firstWhere(
                (a) => a.type == InternetAddressType.IPv4,
            orElse: () => InternetAddress.loopbackIPv4);
        return first.address;
      }
    } catch (e) {
      debugPrint('Error listing network interfaces: $e');
    }
    return InternetAddress.loopbackIPv4.address;
  }

  bool _isPrivateIp(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    final parts = ip.split('.');
    if (parts.length == 4) {
      final first = int.tryParse(parts[0]) ?? 0;
      final second = int.tryParse(parts[1]) ?? 0;
      if (first == 172 && (second >= 16 && second <= 31)) return true;
    }
    return false;
  }

  Future<void> _startServer() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort);
      final ip = await _getLocalIpForDisplay();

      setState(() {
        sessionActive = true;
        advertising = true;
        serverIp = ip;
        connectedCount = 0;
        _recentLogs.clear();
      });

      _log('Session started. Listening on $ip:$serverPort');

      _server!.listen((HttpRequest request) async {
        try {
          if (request.method == 'POST' &&
              (request.uri.path == '/attendance' || request.uri.path == '/submit_attendance' || request.uri.path == '/submit')) {
            final payloadString = await utf8.decoder.bind(request).join();
            final dynamic decoded = jsonDecode(payloadString);
            if (decoded is Map<String, dynamic>) {
              final int processed = await _processAttendancePayload(decoded);
              receivedBatches += 1;
              receivedRecordsTotal += processed;
              lastReceivedAt = DateTime.now();

              request.response.statusCode = 200;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'status': 'ok', 'received': processed}));
              _log('Received batch: $processed records (totalRecords: $receivedRecordsTotal)');
            } else {
              request.response.statusCode = 400;
              request.response.write('Expected JSON object at root');
            }
          } else {
            request.response.statusCode = 404;
            request.response.write('Not found');
          }
        } catch (e, st) {
          debugPrint('Error handling request: $e\n$st');
          try {
            request.response.statusCode = 500;
            request.response.write('Internal server error: $e');
          } catch (_) {}
        } finally {
          try {
            await request.response.close();
          } catch (_) {}
          if (mounted) setState(() {});
        }
      }, onError: (e) {
        debugPrint('HTTP server listen error: $e');
      });
    } catch (e) {
      debugPrint('Failed to start server: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start server: $e')));
      }
      await _stopServer();
    }
  }

  Future<void> _stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (e) {
      debugPrint('Error while stopping server: $e');
    }
    _server = null;
    setState(() {
      sessionActive = false;
      advertising = false;
      serverIp = 'Not started';
      connectedCount = 0;
    });
    _log('Session stopped.');
  }

  void _log(String text) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    _recentLogs.insert(0, '[$time] $text');
    if (_recentLogs.length > 50) _recentLogs.removeLast();
    if (mounted) setState(() {});
  }

  Future<int> _processAttendancePayload(Map<String, dynamic> map) async {
    try {
      if (map.containsKey('type') && map['type'] != 'ATT_DATA') {
        _log('Ignored payload with unsupported type: ${map['type']}');
        return 0;
      }

      final sectionCode = (map['Section'] ?? map['section'] ?? '') as String;
      final dateStr = (map['Date'] ?? map['date']) as String?;
      final slotStr = (map['Slot'] ?? map['slot']) as String? ?? 'FN';
      final recordsRaw = map['Records'] ?? map['records'];

      if (sectionCode.isEmpty) return 0;
      if (dateStr == null || dateStr.isEmpty) return 0;
      if (recordsRaw == null || recordsRaw is! List) return 0;

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
          continue;
        }

        final status = (r['Status'] ?? r['status']) as String? ?? 'Present';
        final odStatus = (r['ODStatus'] ?? r['od_status'] ?? 'Normal') as String;
        final timeRaw = (r['Time'] ?? r['time']) as String? ?? DateTime.now().toIso8601String();

        await DBHelper().upsertAttendance(
          studentId: studentIdToUse ?? '',
          sectionCode: sectionCode ?? '',
          date: dateStr,
          slot: slotStr ?? '',
          status: status ?? 'Present',
          odStatus: odStatus ?? 'Normal',
          time: timeRaw,
          source: 'advisor',
        );

        processed += 1;
      }

      return processed;
    } catch (e, st) {
      debugPrint('Error processing attendance payload: $e\n$st');
      return 0;
    }
  }

  void _openSection(String code) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CoordinatorSectionDetailPage(sectionCode: code, date: date),
    ));
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

  Future<void> _generateAllSectionsWeeklyPdf() async {
    try {
      await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {}
    try {
      await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx');
    } catch (e) {}

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
        String shortStatus;
        if (status == 'Present') shortStatus = 'P';
        else if (status == 'Absent') shortStatus = 'A';
        else if (status == 'OD') shortStatus = 'OD';
        else shortStatus = '-';
        (studentMap[sid]!['daily'] as Map<String, String>)[dateKey] = shortStatus;
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

    final filename =
        'weekly_report_all_${DateFormat('yyyyMMdd').format(weekDates.first)}_${DateFormat('yyyyMMdd').format(weekDates.last)}.pdf';
    await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: filename);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Weekly PDF generated')));
    }
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
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
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
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
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
                      : ListView.builder(
                    itemCount: _recentLogs.length,
                    itemBuilder: (context, idx) => Text(_recentLogs[idx], style: const TextStyle(fontSize: 12)),
                  ),
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
    'total': 0, 'present': 0, 'absent': 0, 'od': 0, 'percent': 0.0, 'sectionBreakdown': {}
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
        try { await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx'); } catch (e) {}
        try { await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx'); } catch (e) {}
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

  Color _getStatusColor(String displayStatus) {
    switch (displayStatus) {
      case 'Present': return Colors.green;
      case 'Absent': return Colors.red;
      case 'OD': return Colors.blue;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sectionBreakdown = summary['sectionBreakdown'] as Map<String, Map<String, int>>? ?? {};
    return Scaffold(
      appBar: AppBar(title: Text('Cumulative Report – ${widget.date}')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text('All Sections Combined', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatBox(label: 'Total', value: '${summary['total']}'),
                    const SizedBox(width: 8),
                    _StatBox(label: 'Present', value: '${summary['present']}'),
                    const SizedBox(width: 8),
                    _StatBox(label: 'Absent', value: '${summary['absent']}'),
                    const SizedBox(width: 8),
                    _StatBox(label: 'OD', value: '${summary['od']}'),
                    const SizedBox(width: 8),
                    _StatBox(label: 'Percent', value: '${(summary['percent'] as double).toStringAsFixed(1)}%'),
                  ],
                ),
              ],
            ),
          ),
          if (sectionBreakdown.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Section-wise Breakdown:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...sectionBreakdown.entries.map((entry) {
                    final sectionCode = entry.key;
                    final data = entry.value;
                    final sectionPercent = data['total']! == 0 ? 0.0 : (data['present']! * 100.0 / data['total']!);
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Expanded(flex: 2, child: Text(sectionCode, style: const TextStyle(fontWeight: FontWeight.bold))),
                          Expanded(child: Text('T: ${data['total']}')),
                          Expanded(child: Text('P: ${data['present']}')),
                          Expanded(child: Text('A: ${data['absent']}')),
                          Expanded(child: Text('OD: ${data['od']}')),
                          Expanded(child: Text('${sectionPercent.toStringAsFixed(1)}%')),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No attendance data found.'))
                : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final displayStatus = _getDisplayStatus(r);
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(r['section_code'] ?? '', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(r['name'] ?? ''),
                    subtitle: Text('Reg: ${r['reg_no']} | Gender: ${r['gender']} | H/D: ${r['hd']}'),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _getStatusColor(displayStatus).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _getStatusColor(displayStatus), width: 1),
                      ),
                      child: Text(displayStatus, style: TextStyle(color: _getStatusColor(displayStatus), fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  const _StatBox({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withOpacity(.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// 🔥 REPLACED PLACEHOLDER WITH FULL FUNCTIONAL PAGE
class CoordinatorSectionDetailPage extends StatefulWidget {
  final String sectionCode;
  final String date;
  const CoordinatorSectionDetailPage({super.key, required this.sectionCode, required this.date});

  @override
  State<CoordinatorSectionDetailPage> createState() => _CoordinatorSectionDetailPageState();
}

class _CoordinatorSectionDetailPageState extends State<CoordinatorSectionDetailPage> {
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic> summary = {'total': 0, 'present': 0, 'absent': 0, 'od': 0, 'percent': 0.0};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => isLoading = true);
    final r = await DBHelper().getAttendanceForSectionByDate(widget.sectionCode, widget.date);
    final s = await DBHelper().getSectionSummary(widget.sectionCode, widget.date);
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
    try { await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx'); } catch (e) {}
    try { await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx'); } catch (e) {}

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
        if (status == 'Present') shortStatus = 'P';
        else if (status == 'Absent') shortStatus = 'A';
        else if (status == 'OD') shortStatus = 'OD';
        else shortStatus = '-';
        (studentMap[sid]!['daily'] as Map<String, String>)[dateKey] = shortStatus;
      }
    }

    final students = studentMap.values.toList()
      ..sort((a, b) => (a['reg_no'] as String).compareTo(b['reg_no'] as String));

    final pdfBytes = await WeeklyReport.generateForSection(
      sectionCode: widget.sectionCode,
      weekDates: weekDates,
      students: students,
    );

    final filename = 'weekly_report_${widget.sectionCode}_${DateFormat('yyyyMMdd').format(weekDates.first)}.pdf';
    await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: filename);
  }

  String _getDisplayStatus(Map<String, dynamic> record) {
    final status = record['status'] as String? ?? 'Present';
    final odStatus = record['od_status'] as String? ?? 'Normal';
    if (status == 'Absent') return 'Absent';
    if (odStatus == 'OD') return 'OD';
    return 'Present';
  }

  Color _getStatusColor(String displayStatus) {
    switch (displayStatus) {
      case 'Present': return Colors.green;
      case 'Absent': return Colors.red;
      case 'OD': return Colors.blue;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Section ${widget.sectionCode} – ${widget.date}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: "Download Weekly Report",
            onPressed: _generateWeeklyReport,
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _StatBox(label: 'Total', value: '${summary['total']}'),
                const SizedBox(width: 8),
                _StatBox(label: 'Present', value: '${summary['present']}'),
                const SizedBox(width: 8),
                _StatBox(label: 'Absent', value: '${summary['absent']}'),
                const SizedBox(width: 8),
                _StatBox(label: 'OD', value: '${summary['od']}'),
                const SizedBox(width: 8),
                _StatBox(label: 'Percent', value: '${(summary['percent'] as double).toStringAsFixed(1)}%'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No data yet'))
                : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final displayStatus = _getDisplayStatus(r);
                  return ListTile(
                    title: Text(r['name'] ?? ''),
                    subtitle: Text(r['reg_no'] ?? ''),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _getStatusColor(displayStatus).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _getStatusColor(displayStatus), width: 1),
                      ),
                      child: Text(
                        displayStatus,
                        style: TextStyle(
                          color: _getStatusColor(displayStatus),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}