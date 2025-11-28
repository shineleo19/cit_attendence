import 'package:flutter/material.dart';
import 'advisor.dart';
import 'coordinator.dart';
import 'db_helper.dart';
import 'hod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Offline Attendance',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        // ... (Keep your existing theme settings)
      ),
      home: const RolePickerPage(),
    );
  }
}

class RolePickerPage extends StatefulWidget {
  const RolePickerPage({super.key});

  @override
  State<RolePickerPage> createState() => _RolePickerPageState();
}

class _RolePickerPageState extends State<RolePickerPage> {
  @override
  void initState() {
    super.initState();
    _initDb();
  }

  Future<void> _initDb() async {
    await DBHelper()
        .importStudentsFromAsset('assets/data/students_master.xlsx');
    await DBHelper().database;
  }

  // NOTE: The _showClearDataDialog and the AppBar Action have been removed from here

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Top Gradient Background
          Container(
            height: MediaQuery.of(context).size.height * 0.40,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF3F51B5), Color(0xFF1A237E)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
          ),
          // 2. Custom App Bar area (Cleaned up)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppBar(
              title: const Text('College Attendance'),
              // Actions removed
            ),
          ),
          // 3. Main Content
          SafeArea(
            child: Column(
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.08),
                Container(
                  padding: const EdgeInsets.all(0),
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(60), // Assuming image is square, this will make it round
                    child: Image.asset(
                      "assets/icon/cit_logo.png", // Replace with your image path
                      width: 120, // Adjust width as needed
                      height: 120, // Adjust height as needed
                      fit: BoxFit.cover, // Adjust fit as needed
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Welcome Back',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  'Select your role to continue',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _RoleCard(
                        title: 'Advisor',
                        subtitle: 'Mark attendance & View reports',
                        icon: Icons.person_rounded,
                        color: Colors.blue.shade700,
                        onTap: () => _navToLogin(context, 'advisor'),
                      ),
                      const SizedBox(height: 16),
                      _RoleCard(
                        title: 'Coordinator',
                        subtitle: 'Manage branches & consolidations',
                        icon: Icons.admin_panel_settings_rounded,
                        color: Colors.teal.shade700,
                        onTap: () => _navToLogin(context, 'coordinator'),
                      ),
                      const SizedBox(height: 16),
                      _RoleCard(
                        title: 'HOD',
                        subtitle: 'View only access',
                        icon: Icons.analytics_rounded,
                        color: Colors.purple.shade700,
                        onTap: () => _navToLogin(context, 'hod'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 90),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _navToLogin(BuildContext ctx, String role) {
    Navigator.push(
      ctx,
      MaterialPageRoute(builder: (_) => LoginPage(role: role)),
    );
  }
}

// ... (Keep _RoleCard, LoginPage, HodPlaceholderPage classes exactly as they were) ...
// (Paste the rest of your existing main.dart code here)
class _RoleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded,
                  size: 16, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  final String role;
  const LoginPage({super.key, required this.role});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final userC = TextEditingController();
  final passC = TextEditingController();
  bool loading = false;
  bool _isObscure = true;
  String? error;

  Future<void> _login() async {
    setState(() {
      loading = true;
      error = null;
    });

    // Simulate small delay for UI smoothness
    await Future.delayed(const Duration(milliseconds: 500));

    final row = await DBHelper().auth(
      userC.text.trim(),
      passC.text.trim(),
      widget.role,
    );

    setState(() => loading = false);

    if (row == null) {
      setState(() => error = 'Invalid credentials for ${widget.role}');
      return;
    }

    if (!mounted) return;

    if (widget.role == 'advisor') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AdvisorHomePage(username: row['username']),
        ),
      );
    } else if (widget.role == 'coordinator') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CoordinatorHomePage(username: row['username']),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HodHomePage(username: row['username'])),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.role.toUpperCase(),
            style: const TextStyle(fontSize: 16, letterSpacing: 1.2)),
      ),
      body: Stack(
        children: [
          // Background Header
          Container(
            height: MediaQuery.of(context).size.height * 0.4,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF3F51B5), Color(0xFF1A237E)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 60),
                  // Icon
                  const Icon(Icons.lock_person_rounded,
                      size: 80, color: Colors.white),
                  const SizedBox(height: 30),
                  // Login Card
                  Card(
                    elevation: 8,
                    shadowColor: Colors.black26,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            "Login",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: userC,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: passC,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                icon: Icon(_isObscure
                                    ? Icons.visibility_off
                                    : Icons.visibility),
                                onPressed: () {
                                  setState(() {
                                    _isObscure = !_isObscure;
                                  });
                                },
                              ),
                            ),
                            obscureText: _isObscure,
                          ),
                          const SizedBox(height: 24),
                          if (error != null)
                            Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline,
                                      color: Colors.red, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      error!,
                                      style: const TextStyle(
                                          color: Colors.red, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ElevatedButton(
                            onPressed: loading ? null : _login,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo,
                              foregroundColor: Colors.white,
                            ),
                            child: loading
                                ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            )
                                : const Text(
                              'LOGIN',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}