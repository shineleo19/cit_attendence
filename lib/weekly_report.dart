
// weekly_report.dart
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/src/pdf/page_format.dart';


/// Utility that generates weekly reports:
/// - generateAll: full report grouped by section (Coordinator)
/// - generateForSection: report for a specific section (Advisor)
class WeeklyReport {
  /// dates is a list of DateTime objects for the days in the week (Monday -> Saturday)
  static List<String> _dateHeaders(List<DateTime> dates) {
    final df = DateFormat('dd-MM');
    return dates.map((d) => df.format(d)).toList();
  }

  /// Input structure for students data:
  /// List of maps with keys:
  /// - 'student_id', 'reg_no', 'name', 'section_code'
  /// - 'daily' -> Map<String(date yyyy-MM-dd) , String(status)>
  /// - 'present_count', 'absent_count'
  static Future<Uint8List> generateAll({
    required List<DateTime> weekDates,
    required List<Map<String, dynamic>> rows,
  }) async {
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings = weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    // Group rows by section_code (rows already sorted by section, but ensure grouping)
    final Map<String, List<Map<String, dynamic>>> bySection = {};
    for (final r in rows) {
      final sec = r['section_code'] as String? ?? 'Unknown';
      bySection.putIfAbsent(sec, () => []).add(r);
    }

    // For each section produce a heading and one big table
    for (final entry in bySection.entries) {
      final sectionCode = entry.key;
      final students = entry.value;

      // Build table headers
      final headers = <String>['RegNo', 'Name'] + dateHeaders + ['Present', 'Absent', '%'];

      final data = <List<String>>[];
      for (final s in students) {
        final row = <String>[];
        row.add(s['reg_no'] ?? '');
        row.add(s['name'] ?? '');

        final daily = s['daily'] as Map<String, String>? ?? {};

        int present = 0;
        int absent = 0;

        for (final dateKey in weekDateStrings) {
          final status = daily[dateKey];
          if (status == null) {
            row.add('-'); // no record
          } else {
            row.add(status);
            if (status == 'Present') present++;
            if (status == 'Absent') absent++;
          }
        }

        row.add(present.toString());
        row.add(absent.toString());
        final denom = (present + absent) == 0 ? 1 : (present + absent);
        final percent = ((present * 100.0) / denom);
        row.add(percent.toStringAsFixed(1) + '%');

        data.add(row);
      }

      // Add a section page
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return [
              pw.Header(
                level: 0,
                child: pw.Text('Weekly Report — Section: $sectionCode',
                    style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 6),
              pw.Text('Week: ${DateFormat('dd MMM yyyy').format(weekDates.first)} - ${DateFormat('dd MMM yyyy').format(weekDates.last)}'),
              pw.SizedBox(height: 12),
              pw.Table.fromTextArray(
                headers: headers,
                data: data,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
                headerDecoration: pw.BoxDecoration(color: PdfColors.grey300),
                cellPadding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              ),
            ];
          },
        ),
      );
    }

    return pdf.save();
  }

  static Future<Uint8List> generateForSection({
    required String sectionCode,
    required List<DateTime> weekDates,
    required List<Map<String, dynamic>> students,
  }) async {
    // Reuse generateAll by creating a single-section rows list
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings = weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    final headers = <String>['RegNo', 'Name'] + dateHeaders + ['Present', 'Absent', '%'];

    final data = <List<String>>[];
    for (final s in students) {
      final row = <String>[];
      row.add(s['reg_no'] ?? '');
      row.add(s['name'] ?? '');

      final daily = s['daily'] as Map<String, String>? ?? {};

      int present = 0;
      int absent = 0;

      for (final dateKey in weekDateStrings) {
        final status = daily[dateKey];
        if (status == null) {
          row.add('-');
        } else {
          row.add(status);
          if (status == 'Present') present++;
          if (status == 'Absent') absent++;
        }
      }

      row.add(present.toString());
      row.add(absent.toString());
      final denom = (present + absent) == 0 ? 1 : (present + absent);
      final percent = ((present * 100.0) / denom);
      row.add(percent.toStringAsFixed(1) + '%');

      data.add(row);
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text('Weekly Report — Section: $sectionCode',
                  style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Week: ${DateFormat('dd MMM yyyy').format(weekDates.first)} - ${DateFormat('dd MMM yyyy').format(weekDates.last)}'),
            pw.SizedBox(height: 12),
            pw.Table.fromTextArray(
              headers: headers,
              data: data,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
              headerDecoration: pw.BoxDecoration(color: PdfColors.grey300),
              cellPadding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            ),
          ];
        },
      ),
    );
    return pdf.save();
  }
}