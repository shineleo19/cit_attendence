// advisor.dart
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'db_helper.dart';
import 'package:printing/printing.dart';
import 'weekly_report.dart';

class AdvisorHomePage extends StatefulWidget {
  final String username;
  const AdvisorHomePage({super.key, required this.username});

  @override
  State<AdvisorHomePage> createState() => _AdvisorHomePageState();
}

class _AdvisorHomePageState extends State<AdvisorHomePage> {
  late Future<List<Map<String, dynamic>>> _sectionsFuture;

  @override
  void initState() {
    super.initState();
    _sectionsFuture = DBHelper().getSections();
  }

  /// Monday->Saturday for a given date (today used)
  List<DateTime> _computeWeekRangeForDate(DateTime dt) {
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    return List.generate(6, (i) => monday.add(Duration(days: i)));
  }

  Future<void> _generateSectionWeeklyPdf(String sectionCode) async {
    // ensure students loaded (as coordinator we did it earlier; still try)
    try {
      await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {}
    try {
      await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx');
    } catch (e) {}

    // week based on today
    final today = DateTime.now();
    final weekDates = _computeWeekRangeForDate(today);
    final start = DateFormat('yyyy-MM-dd').format(weekDates.first);
    final end = DateFormat('yyyy-MM-dd').format(weekDates.last);

    // Fetch raw attendance for the range (only rows that match section)
    final allRaw = await DBHelper().getStudentAttendanceBetween(start, end);

    // Filter by sectionCode and build student maps
    final Map<String, Map<String, dynamic>> studentMap = {};
    for (final r in allRaw) {
      if ((r['section_code'] as String?) != sectionCode) continue;
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

    final students = studentMap.values.toList()
      ..sort((a, b) => (a['reg_no'] as String).compareTo(b['reg_no'] as String));

    final pdfBytes = await WeeklyReport.generateForSection(
      sectionCode: sectionCode,
      weekDates: weekDates,
      students: students,
    );

    final filename = 'weekly_report_${sectionCode}_${DateFormat('yyyyMMdd').format(weekDates.first)}.pdf';
    await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: filename);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Section $sectionCode PDF generated')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Advisor – Sections')),
      body: FutureBuilder(
        future: _sectionsFuture,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final sections = snap.data as List<Map<String, dynamic>>;
          return ListView.separated(
            itemCount: sections.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final s = sections[i];
              return ListTile(
                title: Text("CSE-${s['code']}"),
                subtitle: const Text("Tap to mark attendance"),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.download_rounded),
                      tooltip: 'Download weekly report (this section)',
                      onPressed: () => _generateSectionWeeklyPdf(s['code'] as String),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => AdvisorMarkPage(sectionCode: s['code']),
                  ));
                },
              );
            },
          );
        },
      ),
    );
  }
}

// The rest of the advisor file (report page, mark page) is unchanged except imports at top.
// Below is the existing AdvisorReportPage and AdvisorMarkPage (unchanged from your original file),
// with minor additions removed for brevity — keep the rest of your original implementations.
// For completeness I paste them unchanged (from your provided code):

class AdvisorReportPage extends StatefulWidget {
  final String sectionCode;
  final String date;
  const AdvisorReportPage({super.key, required this.sectionCode, required this.date});

  @override
  State<AdvisorReportPage> createState() => _AdvisorReportPageState();
}

class _AdvisorReportPageState extends State<AdvisorReportPage> {
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic> summary = {'total': 0, 'present': 0, 'absent': 0, 'od': 0, 'percent': 0.0};

  Future<void> _load() async {
    rows = await DBHelper().getAttendanceForSectionByDate(widget.sectionCode, widget.date);
    summary = await DBHelper().getSectionSummary(widget.sectionCode, widget.date);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _getDisplayStatus(Map<String, dynamic> record) {
    final status = record['status'] as String? ?? 'Present';
    final odStatus = record['od_status'] as String? ?? 'Normal';

    if (status == 'Absent') {
      return 'Absent';
    } else if (odStatus == 'OD') {
      return 'OD';
    } else {
      return 'Present';
    }
  }

  Color _getStatusColor(String displayStatus) {
    switch (displayStatus) {
      case 'Present':
        return Colors.green;
      case 'Absent':
        return Colors.red;
      case 'OD':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Report – ${widget.sectionCode}'),
        actions: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            tooltip: 'Close Report',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text(
                  'Attendance Report',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Section: ${widget.sectionCode} | Date: ${widget.date}',
                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No data available'))
                : ListView.separated(
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to Sections'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  backgroundColor: Colors.grey[600],
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AdvisorMarkPage extends StatefulWidget {
  final String sectionCode;
  const AdvisorMarkPage({super.key, required this.sectionCode});

  @override
  State<AdvisorMarkPage> createState() => _AdvisorMarkPageState();
}

class _AdvisorMarkPageState extends State<AdvisorMarkPage> {
  final df = DateFormat('yyyy-MM-dd');
  String date = DateFormat('yyyy-MM-dd').format(DateTime.now());
  String slot = 'FN';
  List<Map<String, dynamic>> students = [];
  Map<String, String> status = {};
  Map<String, String> odStatus = {};
  bool loading = true;
  bool discovering = false;
  bool attendanceSubmitted = false;

  final Strategy strategy = Strategy.P2P_STAR;
  final String serviceId = 'com.attendance_cit.app';
  Timer? _discoverTimeout;

  @override
  void initState() {
    super.initState();
    _loadStudents();
  }

  Future<void> _loadStudents() async {
    final list = await DBHelper().getStudentsBySectionCode(widget.sectionCode);
    final statusMap = <String, String>{};
    final odStatusMap = <String, String>{};
    for (var s in list) {
      statusMap[s['id'] as String] = 'Present';
      odStatusMap[s['id'] as String] = 'Normal';
    }
    setState(() {
      students = list;
      status = statusMap;
      odStatus = odStatusMap;
      loading = false;
    });
  }

  Future<void> _markAll(String newStatus) async {
    final statusMap = <String, String>{};
    final odStatusMap = <String, String>{};
    for (var s in students) {
      statusMap[s['id'] as String] = newStatus;
      odStatusMap[s['id'] as String] = 'Normal';
    }
    setState(() {
      status = statusMap;
      odStatus = odStatusMap;
    });
  }

  Future<void> _saveLocally() async {
    final nowIso = DateTime.now().toIso8601String();
    for (var s in students) {
      final id = s['id'] as String;
      await DBHelper().upsertAttendance(
        studentId: id,
        sectionCode: widget.sectionCode,
        date: date,
        slot: slot,
        status: status[id] ?? 'Present',
        odStatus: odStatus[id] ?? 'Normal',
        time: nowIso,
        source: 'advisor',
      );
    }
  }

  Future<void> _submitToCoordinator() async {
    await _saveLocally();

    final records = students.map((s) {
      final id = s['id'] as String;
      return {
        'StudentID': id,
        'Name': s['name'],
        'RegNo': s['reg_no'],
        'Section': s['section_id'],
        'Gender': s['gender'],
        'Quota': s['quota'],
        'HD': s['hd'],
        'Status': status[id] ?? 'Present',
        'ODStatus': odStatus[id] ?? 'Normal',
        'Time': DateTime.now().toIso8601String(),
      };
    }).toList();

    final payload = jsonEncode({
      'type': 'ATT_DATA',
      'Section': widget.sectionCode,
      'Date': date,
      'Slot': slot,
      'Records': records,
    });

    try {
      setState(() => discovering = true);

      await Permission.location.request();
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothAdvertise.request();
      await Permission.nearbyWifiDevices.request();

      await Nearby().stopDiscovery();
      await Nearby().stopAdvertising();

      bool started = await Nearby().startDiscovery(
        'Advisor-${DateTime.now().millisecondsSinceEpoch}',
        strategy,
        serviceId: serviceId,
        onEndpointFound: (id, name, serviceIdFound) async {
          if (name.startsWith('Coordinator')) {
            await Nearby().requestConnection(
              'Advisor',
              id,
              onConnectionInitiated: (id, info) async {
                await Nearby().acceptConnection(
                  id,
                  onPayLoadRecieved: (endid, pl) {},
                  onPayloadTransferUpdate: (endid, upd) {},
                );
              },
              onConnectionResult: (id, status) async {
                if (status == Status.CONNECTED) {
                  final bytes = Uint8List.fromList(payload.codeUnits);
                  await Nearby().sendBytesPayload(id, bytes);
                  await Future.delayed(const Duration(milliseconds: 300));
                  await Nearby().disconnectFromEndpoint(id);
                  await Nearby().stopDiscovery();
                  if (mounted) {
                    setState(() => attendanceSubmitted = true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Attendance sent to Coordinator')),
                    );
                  }
                }
              },
              onDisconnected: (id) {},
            );
          }
        },
        onEndpointLost: (id) {},
      );

      _discoverTimeout?.cancel();
      _discoverTimeout = Timer(const Duration(seconds: 20), () async {
        if (mounted && discovering) {
          await Nearby().stopDiscovery();
          setState(() => discovering = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No Coordinator found. Make sure session is started.')),
          );
        }
      });

      if (!started) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Discovery failed. Try again.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    } finally {
      if (mounted) setState(() => discovering = false);
      _discoverTimeout?.cancel();
    }
  }

  @override
  void dispose() {
    _discoverTimeout?.cancel();
    Nearby().stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text('Mark – ${widget.sectionCode}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text('Date: $date')),
                DropdownButton<String>(
                  value: slot,
                  items: const [
                    DropdownMenuItem(value: 'FN', child: Text('FN')),
                    DropdownMenuItem(value: 'AN', child: Text('AN')),
                  ],
                  onChanged: (v) => setState(() => slot = v!),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ElevatedButton(onPressed: () => _markAll('Present'), child: const Text('Mark All Present')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _markAll('Absent'),
                  child: const Text('Mark All Absent'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: students.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = students[i];
                final id = s['id'] as String;
                final st = status[id] ?? 'Present';
                final od = odStatus[id] ?? 'Normal';
                final isAbsent = st == 'Absent';

                return ListTile(
                  title: Text('${s['name']}'),
                  subtitle: Text('${s['reg_no']}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isAbsent) ...[
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: (od == 'OD') ? Colors.blue : Colors.grey[300],
                            foregroundColor: (od == 'OD') ? Colors.white : Colors.black87,
                            minimumSize: const Size(50, 36),
                          ),
                          onPressed: () {
                            setState(() {
                              odStatus[id] = (od == 'Normal') ? 'OD' : 'Normal';
                            });
                          },
                          child: const Text('OD'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (st == 'Absent') ? Colors.red : Colors.green,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(80, 36),
                        ),
                        onPressed: () {
                          setState(() {
                            status[id] = (st == 'Present') ? 'Absent' : 'Present';
                            if (status[id] == 'Absent') {
                              odStatus[id] = 'Normal';
                            }
                          });
                        },
                        child: Text(st == 'Present' ? 'PRESENT' : 'ABSENT'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: discovering ? null : _submitToCoordinator,
                    icon: const Icon(Icons.send),
                    label: Text(discovering ? 'Sending…' : 'Submit Attendance'),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
                  ),
                  if (attendanceSubmitted) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => AdvisorReportPage(
                            sectionCode: widget.sectionCode,
                            date: date,
                          ),
                        ));
                      },
                      icon: const Icon(Icons.analytics),
                      label: const Text('View Report'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ],
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

  const _StatBox({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}