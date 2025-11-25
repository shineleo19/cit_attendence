

// coordinator.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
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
  bool advertising = false;
  int connectedCount = 0;

  final Strategy strategy = Strategy.P2P_STAR;
  final String serviceId = 'com.attendance_cit.app';
  final String deviceName = 'Coordinator-${DateTime.now().millisecondsSinceEpoch}';

  final df = DateFormat('yyyy-MM-dd');
  String date = DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _startSession() async {
    try {
      await Permission.location.request();
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothAdvertise.request();
      await Permission.nearbyWifiDevices.request();

      await Nearby().stopDiscovery();
      await Nearby().stopAdvertising();

      final ok = await Nearby().startAdvertising(
        deviceName,
        strategy,
        serviceId: serviceId,
        onConnectionInitiated: (id, info) async {
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (endid, payload) async {
              if (payload.type == PayloadType.BYTES && payload.bytes != null) {
                final text = String.fromCharCodes(payload.bytes!);
                await _handlePayload(text);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Received attendance from $endid')),
                  );
                }
              }
            },
            onPayloadTransferUpdate: (endid, upd) {
              // Optional
            },
          );
        },
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            setState(() => connectedCount += 1);
          }
        },
        onDisconnected: (id) {
          setState(() => connectedCount = (connectedCount > 0) ? connectedCount - 1 : 0);
        },
      );

      setState(() => advertising = ok);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start advertising')),
        );
      }
    } catch (e) {
      setState(() => advertising = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _stopSession() async {
    await Nearby().stopAdvertising();
    setState(() {
      advertising = false;
      connectedCount = 0;
    });
  }

  Future<void> _handlePayload(String text) async {
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      if (map['type'] != 'ATT_DATA') return;

      final sectionCode = map['Section'] as String;
      final dateStr = map['Date'] as String;
      final slotStr = map['Slot'] as String;
      final List records = map['Records'] as List;

      final localStudents = await DBHelper().getStudentsBySectionCode(sectionCode);
      final Map<String, String> regToLocalId = {};
      for (var s in localStudents) {
        final reg = s['reg_no'] as String?;
        final id = s['id'] as String?;
        if (reg != null && id != null) regToLocalId[reg] = id;
      }

      for (final r in records) {
        final incomingReg = r['RegNo'] as String?;
        final incomingStudentId = r['StudentID'] as String?;
        String studentIdToUse;
        if (incomingReg != null && regToLocalId.containsKey(incomingReg)) {
          studentIdToUse = regToLocalId[incomingReg]!;
        } else if (incomingStudentId != null) {
          studentIdToUse = incomingStudentId;
        } else {
          continue;
        }

        await DBHelper().upsertAttendance(
          studentId: studentIdToUse,
          sectionCode: sectionCode,
          date: dateStr,
          slot: slotStr,
          status: r['Status'] as String,
          odStatus: r['ODStatus'] as String? ?? 'Normal',
          time: r['Time'] as String,
          source: 'coordinator',
        );
      }

      if (mounted) setState(() {}); // refresh
    } catch (e, st) {
      debugPrint('Error handling payload: $e\n$st');
    }
  }

  void _openSection(String code) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CoordinatorSectionDetailPage(sectionCode: code, date: date),
    ));
  }

  /// Computes the Monday–Saturday range for the currently selected date string
  List<DateTime> _computeWeekRange(String isoDate) {
    final dt = DateTime.parse(isoDate);
    final monday = dt.subtract(Duration(days: dt.weekday - 1)); // Monday
    final saturday = monday.add(const Duration(days: 5));
    final dates = <DateTime>[];
    for (int i = 0; i < 6; i++) {
      dates.add(monday.add(Duration(days: i)));
    }
    return dates;
  }

  Future<void> _generateAllSectionsWeeklyPdf() async {
    // 1) Ensure students are loaded
    try {
      await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) { }
    try {
      await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx');
    } catch (e) { }

    // 2) Compute week range
    final weekDates = _computeWeekRange(date);
    final start = DateFormat('yyyy-MM-dd').format(weekDates.first);
    final end = DateFormat('yyyy-MM-dd').format(weekDates.last);

    // 3) Fetch attendance rows
    final raw = await DBHelper().getStudentAttendanceBetween(start, end);

    // 4) Process into per-student rows
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
        // 🔥 MODIFIED: Convert full words to abbreviations (P / A / OD)
        String shortStatus;
        if (status == 'Present') {
          shortStatus = 'P';
        } else if (status == 'Absent') {
          shortStatus = 'A'; // (Note: Use 'b' here if you strictly meant 'b')
        } else if (status == 'OD') {
          shortStatus = 'OD';
        } else {
          shortStatus = '-';
        }

        (studentMap[sid]!['daily'] as Map<String, String>)[dateKey] = shortStatus;
      }
    }

    // Convert to list sorted by section/regno
    final rows = studentMap.values.toList()
      ..sort((a, b) {
        final sa = a['section_code'] as String;
        final sb = b['section_code'] as String;
        if (sa != sb) return sa.compareTo(sb);
        return (a['reg_no'] as String).compareTo(b['reg_no'] as String);
      });
    // 5) Generate PDF bytes
    final pdfBytes = await WeeklyReport.generateAll(weekDates: weekDates, rows: rows);

    // 6) Print / Save / Share
    final filename = 'weekly_report_all_${DateFormat('yyyyMMdd').format(weekDates.first)}_${DateFormat('yyyyMMdd').format(weekDates.last)}.pdf';
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
                  onPressed: advertising ? _stopSession : _startSession,
                  child: Text(advertising ? 'Stop Session' : 'Start Session'),
                ),
                const SizedBox(width: 12),
                Text('Connected: $connectedCount'),
              ],
            ),
          ),

          // NEW: Weekly report generator for all sections
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
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final sections = snap.data!;
                if (sections.isEmpty) {
                  return const Center(child: Text('No sections available'));
                }
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
        ],
      ),
    );
  }
}

// Rest of the coordinator detail + cumulative pages unchanged, except small imports at top
// (I left them as in your original file but kept their code — below are included unchanged)

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
    // 🔥 FIX: Trigger the loading sequence immediately
    _initPage();
  }

  Future<void> _initPage() async {
    // 1. Ensure student master data exists (if needed), but DO NOT clear it blindly.
    // We removed 'clearStudentsAndSections()' to prevent accidental data loss
    // during report viewing.
    await _prepareCoordinatorData();

    // 2. Now fetch the actual report data
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
      // FIX: Instead of getStudentCount(), we just try to fetch sections.
      // If sections exist, we assume students exist.
      final sections = await DBHelper().getSections();

      if (sections.isEmpty) {
        // If no sections, try to import data
        try {
          await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
        } catch (e) {}
        try {
          await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx');
        } catch (e) {}
      }
    } catch (e) {
      debugPrint("Coordinator import failed: $e");
    }
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
    final sectionBreakdown =
        summary['sectionBreakdown'] as Map<String, Map<String, int>>? ?? {};

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
                const Text(
                  'All Sections Combined',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatBox(
                        label: 'Total', value: '${summary['total']}'),
                    const SizedBox(width: 8),
                    _StatBox(
                        label: 'Present', value: '${summary['present']}'),
                    const SizedBox(width: 8),
                    _StatBox(
                        label: 'Absent', value: '${summary['absent']}'),
                    const SizedBox(width: 8),
                    _StatBox(label: 'OD', value: '${summary['od']}'),
                    const SizedBox(width: 8),
                    _StatBox(
                        label: 'Percent',
                        value:
                        '${(summary['percent'] as double).toStringAsFixed(1)}%'),
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
                  const Text(
                    'Section-wise Breakdown:',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ...sectionBreakdown.entries.map((entry) {
                    final sectionCode = entry.key;
                    final data = entry.value;
                    final sectionPercent = data['total']! == 0
                        ? 0.0
                        : (data['present']! * 100.0 / data['total']!);
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.grey.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              sectionCode,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          Expanded(child: Text('T: ${data['total']}')),
                          Expanded(child: Text('P: ${data['present']}')),
                          Expanded(child: Text('A: ${data['absent']}')),
                          Expanded(child: Text('OD: ${data['od']}')),
                          Expanded(
                              child: Text(
                                  '${sectionPercent.toStringAsFixed(1)}%')),
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
                ? const Center(child: Text('No attendance data found for this date.'))
                : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) =>
                const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final displayStatus = _getDisplayStatus(r);
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        r['section_code'] ?? '',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(r['name'] ?? ''),
                    subtitle: Text(
                      'Reg: ${r['reg_no']} | Sec: ${r['section_code'] ?? ''} | '
                          'Gender: ${r['gender']} | Quota: ${r['quota']} | H/D: ${r['hd']}',
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _getStatusColor(displayStatus)
                            .withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: _getStatusColor(displayStatus),
                            width: 1),
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
      appBar: AppBar(title: Text('${widget.sectionCode} – ${widget.date}')),
      body: Column(
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