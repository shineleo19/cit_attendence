// weekly_report.dart
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/src/pdf/page_format.dart';

class WeeklyReport {
  static List<String> _dateHeaders(List<DateTime> dates) {
    final df = DateFormat('dd-MM');
    return dates.map((d) => df.format(d)).toList();
  }

  // Convert full status → short code for compact table
  static String _short(String? status) {
    if (status == null) return '-';
    final s = status.toLowerCase();
    if (s == 'present') return 'P';
    if (s == 'absent') return 'A';
    if (s == 'od') return 'OD';
    return status;
  }

  static Future<Uint8List> generateAll({
    required List<DateTime> weekDates,
    required List<Map<String, dynamic>> rows,
  }) async {
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings =
    weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    final Map<String, List<Map<String, dynamic>>> bySection = {};
    for (final r in rows) {
      final sec = r['section_code'] as String? ?? 'Unknown';
      bySection.putIfAbsent(sec, () => []).add(r);
    }

    for (final entry in bySection.entries) {
      final sectionCode = entry.key;
      final students = entry.value;

      final headers = <String>['RegNo', 'Name'] +
          dateHeaders +
          ['Present', 'Absent', '%'];

      final data = <List<String>>[];

      for (final s in students) {
        final row = <String>[];

        row.add(s['reg_no'] ?? '');
        row.add(s['name'] ?? '');

        final daily = s['daily'] as Map<String, String>? ?? {};

        int present = 0;
        int absent = 0;

        for (final dateKey in weekDateStrings) {
          final raw = daily[dateKey];
          final status = raw?.toLowerCase();

          row.add(_short(raw));

          if (status == 'present') present++;
          if (status == 'absent') absent++;
        }

        row.add(present.toString());
        row.add(absent.toString());

        final denom = (present + absent) == 0 ? 1 : (present + absent);
        final percent = (present * 100.0) / denom;

        final percentStr = percent % 1 == 0
            ? percent.toInt().toString() + '%'
            : percent.toStringAsFixed(1) + '%';

        row.add(percentStr);

        data.add(row);
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return [
              pw.Header(
                level: 0,
                child: pw.Text(
                  'Weekly Report — Section: $sectionCode',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'Week: ${DateFormat('dd MMM yyyy').format(weekDates.first)} - '
                    '${DateFormat('dd MMM yyyy').format(weekDates.last)}',
              ),
              pw.SizedBox(height: 12),
              pw.Table.fromTextArray(
                headers: headers,
                data: data,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
                headerDecoration:
                pw.BoxDecoration(color: PdfColors.grey300),
                cellPadding:
                const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
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
    final pdf = pw.Document();
    final dateHeaders = _dateHeaders(weekDates);
    final weekDateStrings =
    weekDates.map((d) => DateFormat('yyyy-MM-dd').format(d)).toList();

    final headers = <String>['RegNo', 'Name'] +
        dateHeaders +
        ['Present', 'Absent', '%'];

    final data = <List<String>>[];

    for (final s in students) {
      final row = <String>[];
      row.add(s['reg_no'] ?? '');
      row.add(s['name'] ?? '');

      final daily = s['daily'] as Map<String, String>? ?? {};

      int present = 0;
      int absent = 0;

      for (final dateKey in weekDateStrings) {
        final raw = daily[dateKey];
        final status = raw?.toLowerCase();

        row.add(_short(raw));

        if (status == 'present') present++;
        if (status == 'absent') absent++;
      }

      row.add(present.toString());
      row.add(absent.toString());

      final denom = (present + absent) == 0 ? 1 : (present + absent);
      final percent = (present * 100.0) / denom;

      final percentStr = percent % 1 == 0
          ? percent.toInt().toString() + '%'
          : percent.toStringAsFixed(1) + '%';

      row.add(percentStr);

      data.add(row);
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text(
                'Weekly Report — Section: $sectionCode',
                style:
                pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Week: ${DateFormat('dd MMM yyyy').format(weekDates.first)} - '
                  '${DateFormat('dd MMM yyyy').format(weekDates.last)}',
            ),
            pw.SizedBox(height: 12),
            pw.Table.fromTextArray(
              headers: headers,
              data: data,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
              headerDecoration:
              pw.BoxDecoration(color: PdfColors.grey300),
              cellPadding:
              const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }
}