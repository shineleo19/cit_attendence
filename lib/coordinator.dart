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
  // ADDED: Clear Data Dialog Logic
  // ---------------------
  void _showClearDataDialog(BuildContext context) {
    final TextEditingController confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 8),
              Text('Clear Database?'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This will permanently delete ALL attendance records.',
                style: TextStyle(color: Colors.black87),
              ),
              const SizedBox(height: 16),
              const Text(
                'Type "confirm" to proceed:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: confirmController,
                decoration: const InputDecoration(hintText: 'confirm'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                if (confirmController.text.trim() == 'confirm') {
                  Navigator.pop(ctx);
                  await DBHelper().clearAttendance();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Attendance table cleared ✅"),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                    // Refresh logs to show action
                    _log("Database cleared by user.");
                  }
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Incorrect text.")),
                  );
                }
              },
              child: const Text('CLEAR'),
            ),
          ],
        );
      },
    );
  }

  // ---------------------
  // HTTP server helpers (Logic unchanged)
  // ---------------------
  Future<String> _getLocalIpForDisplay() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
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
              (request.uri.path == '/attendance' ||
                  request.uri.path == '/submit_attendance' ||
                  request.uri.path == '/submit')) {
            final payloadString = await utf8.decoder.bind(request).join();
            final dynamic decoded = jsonDecode(payloadString);
            if (decoded is Map<String, dynamic>) {
              final int processed = await _processAttendancePayload(decoded);
              receivedBatches += 1;
              receivedRecordsTotal += processed;
              lastReceivedAt = DateTime.now();

              request.response.statusCode = 200;
              request.response.headers.contentType = ContentType.json;
              request.response
                  .write(jsonEncode({'status': 'ok', 'received': processed}));
              _log(
                  'Received batch: $processed records (Total: $receivedRecordsTotal)');
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
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to start server: $e')));
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

      final localStudents =
      await DBHelper().getStudentsBySectionCode(sectionCode);
      final Map<String, String> regToLocalId = {};
      for (var s in localStudents) {
        final reg = s['reg_no'] as String?;
        final id = s['id'] as String?;
        if (reg != null && id != null) regToLocalId[reg] = id;
      }

      int processed = 0;

      for (final dynamic r in recordsRaw) {
        if (r is! Map<String, dynamic>) continue;

        final incomingReg =
        (r['RegNo'] ?? r['reg_no'] ?? r['Regno'] ?? r['regNo']) as String?;
        final incomingStudentId =
        (r['StudentID'] ?? r['studentId'] ?? r['student_id']) as String?;

        String? studentIdToUse;
        if (incomingReg != null && regToLocalId.containsKey(incomingReg)) {
          studentIdToUse = regToLocalId[incomingReg];
        } else if (incomingStudentId != null && incomingStudentId.isNotEmpty) {
          studentIdToUse = incomingStudentId;
        } else {
          continue;
        }

        final status = (r['Status'] ?? r['status']) as String? ?? 'Present';
        final odStatus =
        (r['ODStatus'] ?? r['od_status'] ?? 'Normal') as String;
        final timeRaw = (r['Time'] ?? r['time']) as String? ??
            DateTime.now().toIso8601String();

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
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              CoordinatorSectionDetailPage(sectionCode: code, date: date),
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
      await DBHelper()
          .importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {}
    try {
      await DBHelper()
          .importStudentsFromExcel('/mnt/data/students_master.xlsx');
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

    final rows = studentMap.values.toList()
      ..sort((a, b) {
        final sa = a['section_code'] as String;
        final sb = b['section_code'] as String;
        if (sa != sb) return sa.compareTo(sb);
        return (a['reg_no'] as String).compareTo(b['reg_no'] as String);
      });

    final pdfBytes =
    await WeeklyReport.generateAll(weekDates: weekDates, rows: rows);

    final filename =
        'weekly_report_all_${DateFormat('yyyyMMdd').format(weekDates.first)}_${DateFormat('yyyyMMdd').format(weekDates.last)}.pdf';
    await Printing.layoutPdf(
        onLayout: (format) async => pdfBytes, name: filename);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Weekly PDF generated'),
        backgroundColor: Colors.green,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Coordinator Dashboard'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        centerTitle: true,
        // --- ADDED: Action Button for Clear Data ---
        actions: [
          IconButton(
            tooltip: "Clear Data",
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: () => _showClearDataDialog(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildServerPanel(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildActionButtons(),
                  const SizedBox(height: 24),
                  const Text(
                    "Sections",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  _buildSectionList(),
                  const SizedBox(height: 24),
                  const Text(
                    "Server Logs",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  _buildLogConsole(),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.indigo,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  sessionActive
                      ? Icons.wifi_tethering
                      : Icons.wifi_tethering_off,
                  color: sessionActive ? Colors.greenAccent : Colors.white54,
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sessionActive ? serverIp : "Server Offline",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      sessionActive
                          ? "Port: $serverPort"
                          : "Tap start to listen",
                      style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: sessionActive ? _stopServer : _startServer,
                icon: Icon(sessionActive
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded),
                label: Text(sessionActive ? 'STOP SESSION' : 'START SESSION'),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                  sessionActive ? Colors.redAccent : Colors.white,
                  foregroundColor: sessionActive ? Colors.white : Colors.indigo,
                  padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_download_outlined,
                        color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      "$receivedRecordsTotal Rec",
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _ActionCard(
            title: 'Weekly Report',
            subtitle: 'Download PDF',
            icon: Icons.picture_as_pdf_rounded,
            color: Colors.green,
            onTap: _generateAllSectionsWeeklyPdf,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionCard(
            title: 'Cumulative',
            subtitle: 'View Analytics',
            icon: Icons.analytics_rounded,
            color: Colors.orange,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => CumulativeReportPage(date: date)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionList() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: DBHelper().getSections(),
      builder: (context, snap) {
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final sections = snap.data!;
        if (sections.isEmpty) {
          return const Center(child: Text('No sections available'));
        }
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: sections.length,
          itemBuilder: (_, i) {
            final s = sections[i];
            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300)),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.indigo.shade50,
                  child: Text(s['code'].substring(0, 1),
                      style: const TextStyle(color: Colors.indigo)),
                ),
                title: Text("Section ${s['code']}",
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Tap to view details"),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => _openSection(s['code'] as String),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLogConsole() {
    return Container(
      height: 180,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: _recentLogs.isEmpty
          ? Center(
        child: Text(
          'Waiting for connections...',
          style: TextStyle(
              color: Colors.grey.shade600, fontFamily: 'monospace'),
        ),
      )
          : ListView.builder(
        itemCount: _recentLogs.length,
        itemBuilder: (context, idx) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _recentLogs[idx],
              style: const TextStyle(
                color: Color(0xFF00FF00), // Matrix Green
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(title,
                style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(subtitle,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
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

  // ... (Reuse _computeWeekRange and _generateWeeklyReport from your original logic) ...
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