import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'db_helper.dart';
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

  List<DateTime> _computeWeekRangeForDate(DateTime dt) {
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    return List.generate(6, (i) => monday.add(Duration(days: i)));
  }

  Future<void> _generateSectionWeeklyPdf(String sectionCode) async {
    try {
      await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {}
    try {
      await DBHelper().importStudentsFromExcel('/mnt/data/students_master.xlsx');
    } catch (e) {}

    final today = DateTime.now();
    final weekDates = _computeWeekRangeForDate(today);
    final start = DateFormat('yyyy-MM-dd').format(weekDates.first);
    final end = DateFormat('yyyy-MM-dd').format(weekDates.last);

    final allRaw = await DBHelper().getStudentAttendanceBetween(start, end);

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
      sectionCode: sectionCode,
      weekDates: weekDates,
      students: students,
    );

    final filename = 'weekly_report_${sectionCode}_${DateFormat('yyyyMMdd').format(weekDates.first)}.pdf';
    await Printing.layoutPdf(onLayout: (format) async => pdfBytes, name: filename);
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
                      tooltip: 'Download weekly report',
                      onPressed: () => _generateSectionWeeklyPdf(s['code'] as String),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () async {
                  // 🔥 Pre-fetch students before navigating to AdvisorPage
                  final students = await DBHelper().getStudentsBySectionCode(s['code']);
                  if (!context.mounted) return;
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => AdvisorPage(
                      section: s['code'],
                      username: widget.username,
                      students: students,
                    ),
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

// 🔥 Updated AdvisorPage (HTTP version)
class AdvisorPage extends StatefulWidget {
  final String section;
  final String username;
  final List<Map<String, dynamic>> students;
  final Function()? onSubmitComplete;

  const AdvisorPage({
    super.key,
    required this.section,
    required this.students,
    this.onSubmitComplete,
    required this.username,
  });

  @override
  State<AdvisorPage> createState() => _AdvisorPageState();
}

class _AdvisorPageState extends State<AdvisorPage> {
  String slot = "FN";
  late DateTime selectedDate;
  late List<Map<String, dynamic>> students;

  Map<String, String> status = {};
  Map<String, String> odStatus = {};

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: "4040");
  bool isSubmitting = false;

  @override
  void initState() {
    super.initState();
    students = widget.students;
    selectedDate = DateTime.now();

    for (var s in students) {
      String id = s['id'];
      status[id] = 'Present';
      odStatus[id] = 'Normal';
    }
  }

  Future<void> _saveLocally() async {
    // 🔥 Integrated SQLite saving logic so data persists offline
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(selectedDate);
      for (var s in students) {
        final id = s['id'] as String;
        await DBHelper().upsertAttendance(
          studentId: id,
          sectionCode: widget.section,
          date: dateStr,
          slot: slot,
          status: status[id] ?? 'Present',
          odStatus: odStatus[id] ?? 'Normal',
          time: DateTime.now().toIso8601String(),
          source: 'advisor_http',
        );
      }
      debugPrint("Locally saved attendance for ${widget.section}");
    } catch (e) {
      debugPrint("Error saving locally: $e");
    }
  }

  Future<void> _submitToCoordinator() async {
    if (_ipController.text.trim().isEmpty) {
      _showMessage("⚠ Enter Coordinator IP", Colors.orange);
      return;
    }

    setState(() => isSubmitting = true);

    // 1. Save to local DB first
    await _saveLocally();

    final url = "http://${_ipController.text.trim()}:${_portController.text.trim()}/submit_attendance";

    final recordList = students.map((s) {
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

    final payload = {
      "Date": DateFormat('yyyy-MM-dd').format(selectedDate),
      "Slot": slot,
      "Section": widget.section,
      "Records": recordList,
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        _showMessage("✔ Attendance submitted!", Colors.green);
        if (widget.onSubmitComplete != null) {
          widget.onSubmitComplete!();
        }
      } else {
        _showMessage("❌ Submit Failed (${response.statusCode})", Colors.redAccent);
      }
    } catch (e) {
      _showMessage("❌ Connection Error: $e", Colors.redAccent);
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  void _showMessage(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _toggleStatus(String id) {
    setState(() {
      if (status[id] == 'Present') {
        status[id] = 'Absent';
      } else {
        status[id] = 'Present';
      }
      // If absent, clear OD
      if (status[id] == 'Absent') {
        odStatus[id] = 'Normal';
      }
    });
  }

  void _toggleOD(String id) {
    setState(() {
      if (odStatus[id] == "Normal") {
        odStatus[id] = "OD";
        // If OD, ensure marked present implicitly or handle as needed
      } else {
        odStatus[id] = "Normal";
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Advisor – ${widget.section}"),
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics),
            tooltip: "View Report",
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(
                  builder: (_) => AdvisorReportPage(
                      sectionCode: widget.section,
                      date: DateFormat('yyyy-MM-dd').format(selectedDate)
                  )
              ));
            },
          )
        ],
      ),
      body: Column(
        children: [
          _buildDateSlotRow(),
          _buildCoordinatorIPInput(),
          Expanded(child: _buildStudentList()),
          _buildSubmitButton(),
        ],
      ),
    );
  }

  Widget _buildDateSlotRow() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => selectedDate = picked);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey),
                ),
                child: Text(
                  DateFormat('yyyy-MM-dd').format(selectedDate),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: slot,
            items: ["FN", "AN"].map((e) {
              return DropdownMenuItem(value: e, child: Text(e));
            }).toList(),
            onChanged: (v) => setState(() => slot = v!),
          ),
        ],
      ),
    );
  }

  Widget _buildCoordinatorIPInput() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Coordinator Hotspot IP:", style: TextStyle(fontWeight: FontWeight.bold)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      hintText: "e.g., 192.168.43.1",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStudentList() {
    return ListView.builder(
      itemCount: students.length,
      itemBuilder: (context, i) {
        final s = students[i];
        final id = s['id'];
        final isAbsent = status[id] == 'Absent';
        final isOD = odStatus[id] == 'OD';

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: ListTile(
            title: Text("${s['name']} (${s['reg_no']})"),
            subtitle: Text("Gender: ${s['gender']} | Quota: ${s['quota']}"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () => _toggleStatus(id),
                  child: Chip(
                    label: Text(isAbsent ? 'ABSENT' : 'PRESENT',
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    backgroundColor: isAbsent ? Colors.red : Colors.green,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _toggleOD(id),
                  child: Chip(
                    label: Text(isOD ? 'OD' : 'Normal',
                        style: TextStyle(color: isOD ? Colors.white : Colors.black87, fontSize: 12)),
                    backgroundColor: isOD ? Colors.blue : Colors.grey[300],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSubmitButton() {
    return Container(
      padding: const EdgeInsets.all(12),
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: Colors.green,
        ),
        onPressed: isSubmitting ? null : _submitToCoordinator,
        child: Text(isSubmitting ? "Sending..." : "Submit to Coordinator",
            style: const TextStyle(fontSize: 18, color: Colors.white)),
      ),
    );
  }
}

// Re-including ReportPage so analytics button works
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    rows = await DBHelper().getAttendanceForSectionByDate(widget.sectionCode, widget.date);
    summary = await DBHelper().getSectionSummary(widget.sectionCode, widget.date);
    if(mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Report – ${widget.sectionCode}')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(12),
            color: Colors.blue.withOpacity(0.1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text("Total: ${summary['total']}"),
                Text("Present: ${summary['present']}"),
                Text("Absent: ${summary['absent']}"),
                Text("OD: ${summary['od']}"),
                Text("${(summary['percent'] as double).toStringAsFixed(1)}%"),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                final status = r['status'] == 'Absent' ? 'Absent' : (r['od_status'] == 'OD' ? 'OD' : 'Present');
                Color color = status == 'Absent' ? Colors.red : (status == 'OD' ? Colors.blue : Colors.green);
                return ListTile(
                  title: Text(r['name'] ?? ''),
                  subtitle: Text(r['reg_no'] ?? ''),
                  trailing: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}