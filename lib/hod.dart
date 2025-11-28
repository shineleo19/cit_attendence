import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'db_helper.dart';
import 'coordinator.dart'; // We reuse the detail page from coordinator

class HodHomePage extends StatefulWidget {
  final String username;
  const HodHomePage({super.key, required this.username});

  @override
  State<HodHomePage> createState() => _HodHomePageState();
}

class _HodHomePageState extends State<HodHomePage> {
  DateTime selectedDate = DateTime.now();
  Map<String, dynamic> summary = {
    'total': 0,
    'present': 0,
    'absent': 0,
    'od': 0,
    'percent': 0.0,
    'sectionBreakdown': <String, Map<String, int>>{}
  };
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    // Ensure data exists (HOD needs data to view)
    try {
      await DBHelper().importStudentsFromAsset('assets/data/students_master.xlsx');
    } catch (e) {
      debugPrint("Asset import failed: $e");
    }
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() => isLoading = true);
    final dateStr = DateFormat('yyyy-MM-dd').format(selectedDate);
    final s = await DBHelper().getCumulativeSummary(dateStr);

    if (mounted) {
      setState(() {
        summary = s;
        isLoading = false;
      });
    }
  }

  void _onDateChanged(DateTime? newDate) {
    if (newDate != null) {
      setState(() => selectedDate = newDate);
      _loadReport();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sectionBreakdown = summary['sectionBreakdown'] as Map<String, dynamic>? ?? {};
    final sortedKeys = sectionBreakdown.keys.toList()..sort();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('HOD Dashboard'),
        backgroundColor: Colors.purple.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadReport,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Date Picker Row
            _buildDateSelector(),
            const SizedBox(height: 16),

            // 2. Department Summary Card
            _buildOverallSummaryCard(),
            const SizedBox(height: 24),

            // 3. Section List Header
            const Text(
              "Section Wise Performance",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 12),

            // 4. Section Grid/List
            if (isLoading)
              const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
            else if (sortedKeys.isEmpty)
              _buildEmptyState()
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: sortedKeys.length,
                itemBuilder: (context, index) {
                  final secCode = sortedKeys[index];
                  // sectionBreakdown values are Map<String, int> but coming as dynamic from JSON-like structure
                  final stats = sectionBreakdown[secCode] as Map<String, dynamic>;
                  return _buildSectionCard(secCode, stats);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_today_rounded, color: Colors.purple.shade700),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Report Date", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text(
                    DateFormat('EEE, dd MMM yyyy').format(selectedDate),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
            ],
          ),
          TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
                builder: (ctx, child) {
                  return Theme(
                    data: Theme.of(ctx).copyWith(
                      colorScheme: ColorScheme.light(primary: Colors.purple.shade700),
                    ),
                    child: child!,
                  );
                },
              );
              _onDateChanged(picked);
            },
            child: const Text("Change"),
          )
        ],
      ),
    );
  }

  Widget _buildOverallSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.purple.shade400, Colors.deepPurple.shade700]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.purple.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Department Total", style: TextStyle(color: Colors.white70, fontSize: 14)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  children: [
                    const Icon(Icons.bar_chart, color: Colors.white, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      "${(summary['percent'] as double).toStringAsFixed(1)}%",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              )
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "${summary['total']}",
            style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold),
          ),
          const Text("Students", style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statItem("Present", "${summary['present']}", Colors.greenAccent),
              Container(width: 1, height: 30, color: Colors.white24),
              _statItem("Absent", "${summary['absent']}", Colors.redAccent),
              Container(width: 1, height: 30, color: Colors.white24),
              _statItem("On Duty", "${summary['od']}", Colors.blueAccent),
            ],
          )
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 20)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _buildSectionCard(String code, Map<String, dynamic> stats) {
    final total = stats['total'] as int? ?? 0;
    final present = stats['present'] as int? ?? 0;
    final absent = stats['absent'] as int? ?? 0;

    // Calculate percentage safely
    final percent = total > 0 ? (present / total) * 100 : 0.0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200)
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Navigate to the existing Coordinator Detail Page which is perfect for HOD viewing too
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => CoordinatorSectionDetailPage(
                      sectionCode: code,
                      date: DateFormat('yyyy-MM-dd').format(selectedDate)
                  )
              )
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.purple.shade50,
                child: Text(code.substring(0, 1), style: TextStyle(color: Colors.purple.shade700, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Section $code", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text("$total Students", style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text("${percent.toStringAsFixed(1)}%", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                  Row(
                    children: [
                      Text("P: $present", style: const TextStyle(fontSize: 11, color: Colors.green)),
                      const SizedBox(width: 8),
                      Text("A: $absent", style: const TextStyle(fontSize: 11, color: Colors.red)),
                    ],
                  )
                ],
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.bar_chart_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text("No Data Available", style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
          const SizedBox(height: 8),
          const Text("Attendance has not been marked\nfor this date yet.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}