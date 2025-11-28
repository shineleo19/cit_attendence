// lib/advisor.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'db_helper.dart';
import 'weekly_report.dart';
import 'wifi_direct_helper.dart';

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
    // Try to start discovery silently when opening the app
    _initDiscovery();
    _sectionsFuture = DBHelper().getSectionsForUser(widget.username);
  }

  Future<void> _initDiscovery() async {
    try {
      await WifiDirectHelper.initialize();
      await WifiDirectHelper.startDiscovery();
    } catch (e) {
      debugPrint("Discovery init error (non-fatal): $e");
    }
  }

  // --- Clear Data Dialog Logic ---
  void _showClearDataDialog(BuildContext context) {
    final TextEditingController confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
      appBar: AppBar(
        title: const Text('My Sections'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: "Clear Data",
            icon: const Icon(Icons.delete_rounded),
            onPressed: () => _showClearDataDialog(context),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _sectionsFuture,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final sections = snap.data as List<Map<String, dynamic>>;

          if (sections.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.class_outlined, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text("No sections assigned", style: TextStyle(color: Colors.grey.shade600)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sections.length,
            itemBuilder: (_, i) {
              final s = sections[i];
              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    final students = await DBHelper().getStudentsBySectionCode(s['code']);
                    if (!context.mounted) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AdvisorPage(
                          section: s['code'],
                          username: widget.username,
                          students: students,
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.indigo.shade50, shape: BoxShape.circle),
                          child: const Icon(Icons.people_alt_rounded, color: Colors.indigo),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Class CSE-${s['code']}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text("Tap to take attendance", style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.picture_as_pdf_rounded, color: Colors.redAccent),
                          tooltip: 'Download Report',
                          onPressed: () => _generateSectionWeeklyPdf(s['code']),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

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

  final TextEditingController _ipController = TextEditingController(text: '192.168.49.1');
  final TextEditingController _portController = TextEditingController(text: '4040');
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

  // --- 1. The Missing Helper Method ---
  void _showMessage(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _saveLocally() async {
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

  // --- 2. Auto-Connect Workflow ---
  Future<void> _submitToCoordinator() async {
    setState(() => isSubmitting = true);
    await _saveLocally(); // Save first

    // Check if user manually typed an IP different from default
    // If they typed a custom IP (like Hotspot IP), use that directly.
    final manualIp = _ipController.text.trim();
    if (manualIp != '192.168.49.1' && manualIp.isNotEmpty) {
      // User is likely using Hotspot, send directly
      await _sendDataToIp(manualIp);
      if(mounted) setState(() => isSubmitting = false);
      return;
    }

    try {
      _showMessage("🔍 Auto-detecting Coordinator...", Colors.blue);

      // Try Auto-Connect logic
      await _autoConnectAndSend();

    } catch (e) {
      // Fallback: If auto-connect fails, try sending to the IP in the box anyway
      // (in case they are already connected via settings)
      debugPrint("Auto-connect failed, trying direct send: $e");
      try {
        await _sendDataToIp('192.168.49.1');
      } catch (e2) {
        _showMessage("❌ Connection failed. Check settings.", Colors.red);
      }
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  Future<void> _autoConnectAndSend() async {
    // A. Discovery
    await WifiDirectHelper.startDiscovery();
    await Future.delayed(const Duration(seconds: 2));

    // B. Get Peers
    final peers = await WifiDirectHelper.getPeers();
    if (peers.isEmpty) {
      // If no peers found, we just return and let the code try the manual IP
      throw Exception("No peers found");
    }

    // C. Connect to the first one (Coordinator)
    final coordinator = peers.first;
    _showMessage("🔗 Connecting to ${coordinator.deviceName}...", Colors.orange);

    final connected = await WifiDirectHelper.connect(coordinator.deviceAddress);
    if (!connected) throw Exception("Connection rejected");

    // D. Wait for IP
    _showMessage("⏳ Stabilizing...", Colors.blue);
    await Future.delayed(const Duration(seconds: 3));

    // E. Send
    await _sendDataToIp('192.168.49.1');

    // F. Disconnect
    await Future.delayed(const Duration(seconds: 1));
    await WifiDirectHelper.disconnect();
    _showMessage("Disconnected.", Colors.grey);
  }

  Future<void> _sendDataToIp(String host) async {
    final port = int.tryParse(_portController.text.trim()) ?? 4040;

    // Prepare JSON
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

    final payloadMap = {
      'type': 'ATT_DATA',
      'Section': widget.section,
      'Date': DateFormat('yyyy-MM-dd').format(selectedDate),
      'Slot': slot,
      'Records': recordList,
    };
    final payload = jsonEncode(payloadMap);

    // Socket Send
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    socket.add(utf8.encode(payload));
    await socket.flush();
    await socket.close();

    _showMessage('✔ Data Sent Successfully!', Colors.green);
    widget.onSubmitComplete?.call();
  }

  void _toggleStatus(String id) {
    setState(() {
      if (status[id] == 'Present') {
        status[id] = 'Absent';
      } else {
        status[id] = 'Present';
      }
      if (status[id] == 'Absent') {
        odStatus[id] = 'Normal';
      }
    });
  }

  void _toggleOD(String id) {
    setState(() {
      if (odStatus[id] == "Normal") {
        odStatus[id] = "OD";
      } else {
        odStatus[id] = "Normal";
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final absents = status.values.where((v) => v == 'Absent').length;
    final ods = odStatus.values.where((v) => v == 'OD').length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Column(
          children: [
            Text("Section ${widget.section}", style: const TextStyle(fontSize: 16)),
            Text("Absent: $absents | OD: $ods", style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: "View Report",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AdvisorReportPage(
                    sectionCode: widget.section,
                    date: DateFormat('yyyy-MM-dd').format(selectedDate),
                  ),
                ),
              );
            },
          )
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: isSubmitting ? null : _submitToCoordinator,
        backgroundColor: isSubmitting ? Colors.grey : Colors.indigo,
        foregroundColor: Colors.white,
        icon: isSubmitting
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.cloud_upload_rounded),
        label: Text(isSubmitting ? "Sending..." : "Submit"),
      ),
      body: Column(
        children: [
          _buildConfigHeader(),
          Expanded(child: _buildStudentList()),
        ],
      ),
    );
  }

  Widget _buildConfigHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                      builder: (ctx, child) => Theme(
                        data: Theme.of(ctx).copyWith(colorScheme: const ColorScheme.light(primary: Colors.indigo)),
                        child: child!,
                      ),
                    );
                    if (picked != null) setState(() => selectedDate = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_rounded, size: 18, color: Colors.indigo),
                        const SizedBox(width: 8),
                        Text(DateFormat('MMM dd, yyyy').format(selectedDate), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(12)),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: slot,
                      isExpanded: true,
                      icon: const Icon(Icons.access_time_filled_rounded, color: Colors.indigo, size: 20),
                      items: ["FN", "AN"].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
                      onChanged: (v) => setState(() => slot = v!),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Icon(Icons.wifi_tethering, color: Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _ipController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: "Coordinator IP (192.168.49.1)",
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                    decoration: const InputDecoration(hintText: "Port", border: InputBorder.none),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentList() {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 80),
      itemCount: students.length,
      itemBuilder: (context, i) {
        final s = students[i];
        final id = s['id'];
        final isAbsent = status[id] == 'Absent';
        final isOD = odStatus[id] == 'OD';

        Color statusColor = Colors.green;
        if (isAbsent) statusColor = Colors.red;
        if (isOD) statusColor = Colors.blue;

        return Card(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: statusColor.withOpacity(0.5), width: 1)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleStatus(id),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(color: statusColor.withOpacity(0.1), shape: BoxShape.circle),
                    child: Center(child: Text(isAbsent ? "A" : (isOD ? "OD" : "P"), style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 18))),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s['name'], style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, decoration: isAbsent ? TextDecoration.lineThrough : null, color: isAbsent ? Colors.grey : Colors.black87)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(4)), child: Text(s['reg_no'], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                            const SizedBox(width: 8),
                            Text("${s['gender']} • ${s['quota']}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Text("OD", style: TextStyle(fontSize: 10, color: isOD ? Colors.blue : Colors.grey)),
                      Switch(value: isOD, activeColor: Colors.blue, onChanged: (val) => _toggleOD(id), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(title: Text('Report: CSE-${widget.sectionCode}'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      body: Column(
        children: [
          _buildSummaryCard(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = rows[i];
                final status = r['status'] == 'Absent' ? 'Absent' : (r['od_status'] == 'OD' ? 'OD' : 'Present');
                Color color = Colors.green;
                IconData icon = Icons.check_circle_outline;
                if (status == 'Absent') { color = Colors.red; icon = Icons.cancel_outlined; }
                else if (status == 'OD') { color = Colors.blue; icon = Icons.school_outlined; }

                return Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(backgroundColor: color.withOpacity(0.1), child: Icon(icon, color: color, size: 20)),
                    title: Text(r['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w500)),
                    subtitle: Text(r['reg_no'] ?? ''),
                    trailing: Text(status.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF5C6BC0), Color(0xFF3949AB)]), borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))]),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _statItem("Total", "${summary['total']}"),
          _statItem("Present", "${summary['present']}"),
          _statItem("Absent", "${summary['absent']}"),
          _statItem("OD", "${summary['od']}"),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
            child: Text("${(summary['percent'] as double).toStringAsFixed(1)}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}