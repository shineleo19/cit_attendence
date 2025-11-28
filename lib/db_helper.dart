import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:excel/excel.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;

class DBHelper {
  static final DBHelper _instance = DBHelper._internal();

  factory DBHelper() => _instance;

  DBHelper._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'attendance.db');
    return openDatabase(
      dbPath,
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
        await _seedData(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await db.execute('''
            ALTER TABLE attendance_records ADD COLUMN od_status TEXT DEFAULT 'Normal';
          ''');
        }
      },
    );
  }

  Future<List<Map<String, dynamic>>> getAbsentStudentsByDate(String date) async {
    final db = await database;
    final sql = '''
      SELECT 
        st.reg_no, 
        st.name, 
        sec.code as section_code 
      FROM attendance_records ar
      INNER JOIN students st ON st.id = ar.student_id
      INNER JOIN sections sec ON sec.id = st.section_id
      WHERE ar.date = ? AND ar.status = 'Absent'
      ORDER BY sec.code ASC, st.reg_no ASC;
    ''';
    return db.rawQuery(sql, [date]);
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE,
        password TEXT,
        role TEXT
      );
    ''');
    await db.execute('''
      CREATE TABLE sections (
        id TEXT PRIMARY KEY,
        code TEXT UNIQUE,
        name TEXT
      );
    ''');
    await db.execute('''
      CREATE TABLE students (
        id TEXT PRIMARY KEY,
        reg_no TEXT UNIQUE,
        name TEXT,
        gender TEXT,
        quota TEXT,
        hd TEXT,
        section_id TEXT,
        FOREIGN KEY(section_id) REFERENCES sections(id)
      );
    ''');
    await db.execute('''
      CREATE TABLE attendance_records (
        id TEXT PRIMARY KEY,
        student_id TEXT,
        section_id TEXT,
        date TEXT,
        slot TEXT,
        status TEXT,
        od_status TEXT DEFAULT 'Normal',
        time TEXT,
        source TEXT,
        created_at TEXT,
        synced INTEGER DEFAULT 0
      );
    ''');
  }

  // ---------------------------------------------------------------------------
  // UPDATED: Authentication to support advisor_p, advisor_a, etc.
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>?> auth(String username, String password, String role) async {
    // 1. Check Hardcoded Specific Advisors First
    if (role == 'advisor') {
      if (username == 'advisor_a' && password == 'classA') return {'username': 'advisor_a', 'role': 'advisor'};
      if (username == 'advisor_b' && password == 'classB') return {'username': 'advisor_b', 'role': 'advisor'};
      if (username == 'advisor_c' && password == 'classC') return {'username': 'advisor_c', 'role': 'advisor'};
      if (username == 'advisor_d' && password == 'classD') return {'username': 'advisor_d', 'role': 'advisor'};
      if (username == 'advisor_e' && password == 'classE') return {'username': 'advisor_e', 'role': 'advisor'};
      if (username == 'advisor_f' && password == 'classF') return {'username': 'advisor_f', 'role': 'advisor'};
      if (username == 'advisor_g' && password == 'classG') return {'username': 'advisor_g', 'role': 'advisor'};
      if (username == 'advisor_h' && password == 'classH') return {'username': 'advisor_h', 'role': 'advisor'};
      if (username == 'advisor_i' && password == 'classI') return {'username': 'advisor_i', 'role': 'advisor'};
      if (username == 'advisor_j' && password == 'classJ') return {'username': 'advisor_j', 'role': 'advisor'};
      if (username == 'advisor_k' && password == 'classK') return {'username': 'advisor_k', 'role': 'advisor'};
      if (username == 'advisor_l' && password == 'classL') return {'username': 'advisor_l', 'role': 'advisor'};
      if (username == 'advisor_m' && password == 'classM') return {'username': 'advisor_m', 'role': 'advisor'};
      if (username == 'advisor_n' && password == 'classN') return {'username': 'advisor_n', 'role': 'advisor'};
      if (username == 'advisor_o' && password == 'classO') return {'username': 'advisor_o', 'role': 'advisor'};
      if (username == 'advisor_p' && password == 'classP') return {'username': 'advisor_p', 'role': 'advisor'};
      if (username == 'advisor_q' && password == 'classQ') return {'username': 'advisor_q', 'role': 'advisor'};
    }

    // 2. Fallback to Database Check
    final db = await database;
    final res = await db.query(
      'users',
      where: 'username=? AND password=? AND role=?',
      whereArgs: [username, password, role],
      limit: 1,
    );
    return res.isEmpty ? null : res.first;
  }

  // ---------------------------------------------------------------------------
  // NEW METHOD: Get Sections Filtered by User (advisor_p -> Section P)
  // ---------------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> getSectionsForUser(String username) async {
    final db = await database;

    String? requiredSection;

    // Define the Mapping
    if (username == 'advisor_a') requiredSection = ' A';
    else if (username == 'advisor_b') requiredSection = ' B';
    else if (username == 'advisor_c') requiredSection = ' C';
    else if (username == 'advisor_d') requiredSection = ' D';
    else if (username == 'advisor_e') requiredSection = ' E';
    else if (username == 'advisor_f') requiredSection = ' F';
    else if (username == 'advisor_g') requiredSection = ' G';
    else if (username == 'advisor_h') requiredSection = ' H';
    else if (username == 'advisor_i') requiredSection = ' I';
    else if (username == 'advisor_j') requiredSection = ' J';
    else if (username == 'advisor_k') requiredSection = ' K';
    else if (username == 'advisor_l') requiredSection = ' L';
    else if (username == 'advisor_m') requiredSection = ' M';
    else if (username == 'advisor_n') requiredSection = ' N';
    else if (username == 'advisor_o') requiredSection = ' O';
    else if (username == 'advisor_q') requiredSection = ' Q';
    else if (username == 'advisor_p') requiredSection = ' P'; // Mapped to section P

    if (requiredSection != null) {
      // Smart search: finds "P", "CSE-P", "Sec-P", "III-CSE-P" etc.
      return await db.rawQuery(
          "SELECT code FROM sections WHERE code = ? OR code = ? OR code LIKE ? ORDER BY code ASC",
          [requiredSection, 'CSE-$requiredSection', '%-$requiredSection']
      );
    }

    // Default: Return all sections (for admin/staff)
    return await db.query(
      'sections',
      columns: ['code'],
      orderBy: 'code ASC',
    );
  }

  // ---------------------------------------------------------------------------
  // EXISTING METHODS (Unchanged)
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getSections() async {
    final db = await database;
    return await db.query(
      'sections',
      columns: ['code'],
      orderBy: 'code ASC',
    );
  }

  Future<void> importStudentsFromExcel(String filePath) async {
    final db = await database;

    if (!File(filePath).existsSync()) return;

    var bytes = File(filePath).readAsBytesSync();
    var excel = Excel.decodeBytes(bytes);

    for (var table in excel.tables.keys) {
      for (var row in excel.tables[table]!.rows.skip(1)) {
        final regNo = row[1]?.value.toString();
        final name = row[2]?.value.toString();
        String? sectionCode = row[3]?.value.toString();
        final gender = row[4]?.value.toString();
        final quota = row[5]?.value.toString();
        final hd = row[6]?.value.toString();

        if (quota != null && quota.toUpperCase() == 'NRI') {
          sectionCode = sectionCode?.replaceAll('-NRI', '');
        }

        var sec = await db.query('sections', where: 'code=?', whereArgs: [sectionCode], limit: 1);
        String sectionId;
        if (sec.isEmpty) {
          sectionId = 'sec_${DateTime.now().millisecondsSinceEpoch}';
          await db.insert('sections', {
            'id': sectionId,
            'code': sectionCode,
            'name': sectionCode,
          });
        } else {
          sectionId = sec.first['id'] as String;
        }

        final studId = '${regNo}_$sectionId';
        await db.insert('students', {
          'id': studId,
          'reg_no': regNo,
          'name': name,
          'gender': gender,
          'quota': quota,
          'hd': hd,
          'section_id': sectionId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<void> importStudentsFromAsset(String assetPath) async {
    final db = await database;

    String normalizeSectionCode(String code, String? quota) {
      if (quota != null && quota.toUpperCase() == 'NRI') {
        return code.replaceAll('-NRI', '');
      }
      return code;
    }

    ByteData data = await rootBundle.load(assetPath);
    var bytes = data.buffer.asUint8List();
    var excel = Excel.decodeBytes(bytes);

    for (var table in excel.tables.keys) {
      for (var row in excel.tables[table]!.rows.skip(1)) {
        final regNo = row[1]?.value.toString();
        final name = row[2]?.value.toString();
        String? sectionCode = row[3]?.value.toString();
        final gender = row[4]?.value.toString();
        final quota = row[5]?.value.toString();
        final hd = row[6]?.value.toString();

        sectionCode = normalizeSectionCode(sectionCode ?? '', quota);

        var sec = await db.query('sections', where: 'code=?', whereArgs: [sectionCode], limit: 1);
        String sectionId;
        if (sec.isEmpty) {
          sectionId = 'sec_${DateTime.now().millisecondsSinceEpoch}';
          await db.insert('sections', {
            'id': sectionId,
            'code': sectionCode,
            'name': sectionCode,
          });
        } else {
          sectionId = sec.first['id'] as String;
        }

        final studId = '${regNo}_$sectionId';
        await db.insert('students', {
          'id': studId,
          'reg_no': regNo,
          'name': name,
          'gender': gender,
          'quota': quota,
          'hd': hd,
          'section_id': sectionId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<void> clearStudentsAndSections() async {
    final db = await database;
    await db.delete('attendance_records');
    await db.delete('students');
    await db.delete('sections');
  }

  Future<List<Map<String, dynamic>>> getAllStudentsWithSection() async {
    final db = await database;
    final sql = '''
      SELECT st.id as student_id, st.reg_no, st.name, sec.code as section_code
      FROM students st
      INNER JOIN sections sec ON sec.id = st.section_id
      ORDER BY sec.code ASC, st.reg_no ASC;
    ''';
    return db.rawQuery(sql);
  }

  Future<List<Map<String, dynamic>>> getStudentsBySectionCode(String code) async {
    final db = await database;
    final s = await db.query('sections', where: 'code=?', whereArgs: [code], limit: 1);
    if (s.isEmpty) return [];
    final sectionId = s.first['id'] as String;
    return await db.query(
      'students',
      where: 'section_id=?',
      whereArgs: [sectionId],
      orderBy: 'reg_no ASC',
      columns: [
        'id',
        'reg_no',
        'name',
        'gender',
        'quota',
        'hd',
        'section_id'
      ],
    );
  }

  Future<void> upsertAttendance({
    required String studentId,
    required String sectionCode,
    required String date,
    required String slot,
    required String status,
    String odStatus = 'Normal',
    required String time,
    required String source,
  }) async {
    final db = await database;

    final s = await db.query('sections', where: 'code=?', whereArgs: [sectionCode], limit: 1);
    if (s.isEmpty) return;
    final sectionId = s.first['id'] as String;

    final id = '$studentId|$date|$slot';
    final now = DateTime.now().toIso8601String();

    await db.insert(
      'attendance_records',
      {
        'id': id,
        'student_id': studentId,
        'section_id': sectionId,
        'date': date,
        'slot': slot,
        'status': status,
        'od_status': odStatus,
        'time': time,
        'source': source,
        'created_at': now,
        'synced': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAttendanceForSectionByDate(String sectionCode, String date) async {
    final db = await database;
    final s = await db.query('sections', where: 'code=?', whereArgs: [sectionCode], limit: 1);
    if (s.isEmpty) return [];
    final sectionId = s.first['id'] as String;
    final sql = '''
      SELECT st.name, st.reg_no, ar.slot, ar.status, ar.od_status, ar.time
      FROM attendance_records ar
      INNER JOIN students st ON st.id = ar.student_id
      WHERE ar.section_id=? AND ar.date=?
      ORDER BY st.reg_no ASC, ar.slot ASC;
    ''';
    return db.rawQuery(sql, [sectionId, date]);
  }

  Future<Map<String, dynamic>> getSectionSummary(String sectionCode, String date) async {
    final rows = await getAttendanceForSectionByDate(sectionCode, date);
    final total = rows.length;
    final present = rows.where((r) => (r['status'] as String) == 'Present').length;
    final absent = total - present;
    final od = rows.where((r) => (r['od_status'] as String?) == 'OD').length;
    final percent = total == 0 ? 0.0 : (present * 100.0 / total);
    return {
      'total': total,
      'present': present,
      'absent': absent,
      'od': od,
      'percent': percent,
    };
  }

  Future<List<Map<String, dynamic>>> getCumulativeAttendanceByDate(String date) async {
    final db = await database;
    final sql = '''
      SELECT 
        sec.code as section_code,
        st.name,
        st.gender,
        st.quota,
        st.hd,
        st.reg_no, 
        ar.slot, 
        ar.status, 
        ar.od_status, 
        ar.time
      FROM attendance_records ar
      INNER JOIN students st ON st.id = ar.student_id
      INNER JOIN sections sec ON sec.id = ar.section_id
      WHERE ar.date=?
      ORDER BY sec.code ASC, st.reg_no ASC, ar.slot ASC;
    ''';
    return db.rawQuery(sql, [date]);
  }

  Future<Map<String, dynamic>> getCumulativeSummary(String date) async {
    final rows = await getCumulativeAttendanceByDate(date);
    final total = rows.length;
    final present = rows.where((r) => (r['status'] as String) == 'Present').length;
    final absent = total - present;
    final od = rows.where((r) => (r['od_status'] as String?) == 'OD').length;
    final percent = total == 0 ? 0.0 : (present * 100.0 / total);

    final sectionBreakdown = <String, Map<String, int>>{};
    for (final row in rows) {
      final sectionCode = row['section_code'] as String;
      final status = row['status'] as String;
      final odStatus = row['od_status'] as String? ?? 'Normal';

      sectionBreakdown[sectionCode] ??= {'total': 0, 'present': 0, 'absent': 0, 'od': 0};
      sectionBreakdown[sectionCode]!['total'] = sectionBreakdown[sectionCode]!['total']! + 1;

      if (status == 'Present') {
        sectionBreakdown[sectionCode]!['present'] = sectionBreakdown[sectionCode]!['present']! + 1;
      } else {
        sectionBreakdown[sectionCode]!['absent'] = sectionBreakdown[sectionCode]!['absent']! + 1;
      }

      if (odStatus == 'OD') {
        sectionBreakdown[sectionCode]!['od'] = sectionBreakdown[sectionCode]!['od']! + 1;
      }
    }

    return {
      'total': total,
      'present': present,
      'absent': absent,
      'od': od,
      'percent': percent,
      'sectionBreakdown': sectionBreakdown,
    };
  }

  Future<void> clearAttendance() async {
    final db = await database;
    await db.delete('attendance_records');
  }

  Future<List<Map<String, dynamic>>> getStudentAttendanceBetween(String startDate, String endDate) async {
    final db = await database;
    final sql = '''
      SELECT 
        st.id AS student_id,
        st.reg_no,
        st.name,
        sec.code AS section_code,
        ar.date,
        ar.status
      FROM students st
      INNER JOIN sections sec ON sec.id = st.section_id
      LEFT JOIN attendance_records ar 
        ON ar.student_id = st.id AND ar.date BETWEEN ? AND ?
      ORDER BY sec.code ASC, st.reg_no ASC, ar.date ASC;
    ''';
    return db.rawQuery(sql, [startDate, endDate]);
  }

  Future<void> _seedData(Database db) async {
    await db.insert('users', {
      'id': 'u1',
      'username': 'advisor1',
      'password': 'pass123',
      'role': 'advisor'
    });
    await db.insert('users', {
      'id': 'u2',
      'username': 'coordinator1',
      'password': 'pass123',
      'role': 'coordinator'
    });
    await db.insert('users', {
      'id': 'u3',
      'username': 'hod1',
      'password': 'pass123',
      'role': 'hod'
    });
  }
}