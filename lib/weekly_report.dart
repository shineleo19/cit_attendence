import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class WeeklyReport {
  static List<String> _dateHeaders(List<DateTime> dates) {
    final df = DateFormat('dd-MM');
    return dates.map((d) => df.format(d)).toList();
  }

  // Convert full status -> short code
  static String _short(String? status) {
    if (status == null) return '-';
    final s = status.toLowerCase();
    if (s == 'present') return 'P';
    if (s == 'absent') return 'A';
    if (s == 'od') return 'OD';
    return status; // Fallback
  }

  // --- GENERATE ALL SECTIONS ---
  static Future<Uint8List> generateAll({
    required List<DateTime> weekDates,
    required List<Map<String, dynamic>> rows,
  }) async {
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings =
    weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    // Group by section
    final Map<String, List<Map<String, dynamic>>> bySection = {};
    for (final r in rows) {
      final sec = r['section_code'] as String? ?? 'Unknown';
      bySection.putIfAbsent(sec, () => []).add(r);
    }

    for (final entry in bySection.entries) {
      final sectionCode = entry.key;
      final students = entry.value;

      // REMOVED: 'Present', '%'
      // KEPT: 'Absent' for reference
      final headers = <String>['RegNo', 'Name'] + dateHeaders + ['Absent'];

      final data = <List<String>>[];

      for (final s in students) {
        final row = <String>[];

        row.add(s['reg_no'] ?? '');
        row.add(s['name'] ?? '');

        final daily = s['daily'] as Map<String, String>? ?? {};

        int absentCount = 0;

        for (final dateKey in weekDateStrings) {
          final raw = daily[dateKey];
          final status = raw?.toLowerCase();

          row.add(_short(raw));

          // Only counting Absent now
          if (status == 'absent' || status == 'a') {
            absentCount++;
          }
        }

        // REMOVED: Present count and Percentage calculation
        row.add(absentCount.toString());

        data.add(row);
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20), // Added cleaner margin
          build: (pw.Context context) {
            return [
              _buildHeader(sectionCode, weekDates),
              pw.SizedBox(height: 15),
              _buildTable(headers, data),
            ];
          },
        ),
      );
    }

    return pdf.save();
  }

  // --- GENERATE SINGLE SECTION ---
  static Future<Uint8List> generateForSection({
    required String sectionCode,
    required List<DateTime> weekDates,
    required List<Map<String, dynamic>> students,
  }) async {
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings =
    weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    // REMOVED: 'Present', '%'
    final headers = <String>['RegNo', 'Name'] + dateHeaders + ['Absent'];

    final data = <List<String>>[];

    for (final s in students) {
      final row = <String>[];
      row.add(s['reg_no'] ?? '');
      row.add(s['name'] ?? '');

      final daily = s['daily'] as Map<String, String>? ?? {};

      int absentCount = 0;

      for (final dateKey in weekDateStrings) {
        final raw = daily[dateKey];
        final status = raw?.toLowerCase();

        row.add(_short(raw));

        if (status == 'absent' || status == 'a') {
          absentCount++;
        }
      }

      // REMOVED: Present count and Percentage calculation
      row.add(absentCount.toString());

      data.add(row);
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(20),
        build: (pw.Context context) {
          return [
            _buildHeader(sectionCode, weekDates),
            pw.SizedBox(height: 15),
            _buildTable(headers, data),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static Future<Uint8List> generateAbsenteeReport({
    required String date,
    required List<Map<String, dynamic>> absentees,
  }) async {
    final pdf = pw.Document();

    // Create table data
    final data = <List<String>>[];
    int sl = 1;

    for (final row in absentees) {
      data.add([
        sl.toString(),
        row['section_code']?.toString() ?? '-',
        row['reg_no']?.toString() ?? '-',
        row['name']?.toString() ?? '-',
      ]);
      sl++;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Daily Absentee Report',
                      style: pw.TextStyle(
                          fontSize: 20, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text('Date: $date',
                      style: const pw.TextStyle(fontSize: 14)),
                  pw.Text('Total Absentees: ${absentees.length}',
                      style: const pw.TextStyle(fontSize: 12, color: PdfColors.red)),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Table.fromTextArray(
              headers: ['S.No', 'Section', 'Reg No', 'Student Name'],
              data: data,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.redAccent),
              cellHeight: 25,
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.center,
                2: pw.Alignment.centerLeft,
                3: pw.Alignment.centerLeft,
              },
              oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }


  // --- UI WIDGET HELPERS ---

  static pw.Widget _buildHeader(String sectionCode, List<DateTime> weekDates) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Weekly Attendance Report',
          style: pw.TextStyle(fontSize: 14, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Section: $sectionCode',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${DateFormat('dd MMM').format(weekDates.first)} - ${DateFormat('dd MMM yyyy').format(weekDates.last)}',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
        pw.Divider(color: PdfColors.grey400),
      ],
    );
  }

  static pw.Widget _buildTable(List<String> headers, List<List<String>> data) {
    return pw.Table.fromTextArray(
      headers: headers,
      data: data,
      border: null, // Cleaner look without heavy grid lines
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
        fontSize: 10,
      ),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo),
      cellStyle: const pw.TextStyle(fontSize: 10),
      cellAlignment: pw.Alignment.center, // Center align data
      // Align Name and RegNo to the left (Indices 0 and 1)
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
      },
      headerHeight: 25,
      cellHeight: 30,
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
    );
  }
}