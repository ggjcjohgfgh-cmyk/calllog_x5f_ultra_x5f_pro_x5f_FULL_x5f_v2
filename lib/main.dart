import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:call_log/call_log.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Color(0xFF07070B)));
  runApp(const CallLogUltraPro());
}

// ─── Design Tokens ───
class K {
  static const bg = Color(0xFF07070B);
  static const primary = Color(0xFF6C5CE7);
  static const teal = Color(0xFF00CEC9);
  static const pink = Color(0xFFFD79A8);
  static const amber = Color(0xFFFDCB6E);
  static const blue = Color(0xFF0984E3);
  static const green = Color(0xFF00B894);
  static const red = Color(0xFFD63031);
  static const gradients = [
    [Color(0xFF6C5CE7), Color(0xFF4834D4)],
    [Color(0xFF00CEC9), Color(0xFF018786)],
    [Color(0xFFFD79A8), Color(0xFFE84393)],
    [Color(0xFFFDCB6E), Color(0xFFE17055)],
    [Color(0xFF0984E3), Color(0xFF0652DD)],
    [Color(0xFF00B894), Color(0xFF006266)],
  ];
}

class CallLogUltraPro extends StatelessWidget {
  const CallLogUltraPro({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'ULTRA PRO 2027',
        theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: K.bg, colorScheme: ColorScheme.fromSeed(seedColor: K.primary, brightness: Brightness.dark)),
        home: const ProHome(),
      );
}

// ─── Fraud Engine ───
enum RiskLevel { safe, suspicious, fraud, critical }

class FraudResult {
  final RiskLevel level;
  final String reason;
  final int score; // 0-100
  FraudResult(this.level, this.reason, this.score);
}

class FraudDetector {
  static final spamPrefixes = ['+44', '+91', '+234', '900', '9200', '1400'];
  static final fraudKeywords = ['بنك', 'جوائز', 'مبروك', 'تحديث بيانات', 'bank', 'prize'];

  static FraudResult analyze(CallLogEntry e, List<CallLogEntry> all) {
    int score = 0;
    String reason = 'رقم آمن';
    final num = e.number ?? '';
    final name = e.name ?? '';

    // 1. رقم مجهول + مكالمة فائتة متكررة
    final sameNumberCalls = all.where((x) => x.number == num).length;
    if (sameNumberCalls >= 5 && (e.callType == CallType.missed)) {
      score += 40;
      reason = 'يتصل كثيراً ولا يترك رسالة - محتمل سبام';
    }
    // 2. رقم قصير / دولي مشبوه
    if (spamPrefixes.any((p) => num.startsWith(p)) || num.length <= 5) {
      score += 50;
      reason = 'رقم دولي / مختصر مشبوه';
    }
    // 3. مدة صفر + فائت
    if ((e.duration ?? 0) == 0 && e.callType == CallType.missed && name.isEmpty) {
      score += 25;
      reason = 'مكالمة فائتة من مجهول - تجاهل وهمي';
    }
    // 4. تكرار في نفس اليوم
    final today = DateTime.now();
    final todayCalls = all.where((x) {
      final d = DateTime.fromMillisecondsSinceEpoch(x.timestamp ?? 0);
      return x.number == num && d.day == today.day;
    }).length;
    if (todayCalls > 3) {
      score += 20;
      reason = 'اتصل $todayCalls مرات اليوم';
    }

    if (score >= 80) return FraudResult(RiskLevel.critical, reason, score);
    if (score >= 50) return FraudResult(RiskLevel.fraud, reason, score);
    if (score >= 25) return FraudResult(RiskLevel.suspicious, reason, score);
    return FraudResult(RiskLevel.safe, reason, score);
  }
}

// ─── Permission Service ───
class PermService {
  static Future<bool> requestAll() async {
    final statuses = await [
      Permission.phone,
      Permission.contacts,
      Permission.sms,
      Permission.microphone,
      Permission.storage,
      Permission.notification,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }
}

// ─── Main Home ───
class ProHome extends StatefulWidget {
  const ProHome({super.key});
  @override
  State<ProHome> createState() => _ProHomeState();
}

enum _Filter { all, incoming, outgoing, missed, blocked, fraud }

class _ProHomeState extends State<ProHome> with TickerProviderStateMixin {
  List<CallLogEntry> all = [];
  List<CallLogEntry> filtered = [];
  Set<String> blocked = {};
  bool loading = true, hasPermission = false;
  _Filter filter = _Filter.all;
  String query = '';
  int _tab = 0; // 0=log, 1=dialer, 2=recordings, 3=shield
  int _analyticsTab = 0;

  late final AnimationController bgCtrl, pulseCtrl, enterCtrl;
  final _searchCtrl = TextEditingController();
  final _dialCtrl = TextEditingController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _isRecording = false;
  List<FileSystemEntity> recordings = [];

  @override
  void initState() {
    super.initState();
    bgCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
    pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
    enterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
    _load();
    _loadRecordings();
  }

  @override
  void dispose() {
    bgCtrl.dispose(); pulseCtrl.dispose(); enterCtrl.dispose();
    _searchCtrl.dispose(); _dialCtrl.dispose();
    _recorder.dispose(); _player.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/recordings');
    if (!await recDir.exists()) await recDir.create(recursive: true);
    setState(() => recordings = recDir.listSync().toList()..sort((a,b) => b.path.compareTo(a.path)));
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      final path = await _recorder.stopRecorder();
      HapticFeedback.mediumImpact();
      setState(() => _isRecording = false);
      _loadRecordings();
      _toast('✅ تم حفظ التسجيل');
    } else {
      if (await _recorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/recordings/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _recorder.startRecorder(toFile: path, codec: RecordCodec.aacLc);
        setState(() => _isRecording = true);
      } else {
        _toast('❌ إذن الميكروفون مطلوب');
      }
    }
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final prefs = await SharedPreferences.getInstance();
    blocked = (prefs.getStringList('blocked') ?? []).toSet();
    final ok = await PermService.requestAll();
    hasPermission = ok || await Permission.phone.isGranted;
    if (hasPermission) {
      try {
        final logs = await CallLog.get().timeout(const Duration(seconds: 15));
        all = logs.where((e) => !blocked.contains(e.number)).toList()..sort((a, b) => (b.timestamp ?? 0).compareTo(a.timestamp ?? 0));
      } catch (_) {}
    }
    _apply();
    setState(() => loading = false);
  }

  void _apply() {
    List<CallLogEntry> list;
    if (filter == _Filter.blocked) {
      list = all.where((e) => blocked.contains(e.number)).toList();
    } else if (filter == _Filter.fraud) {
      list = all.where((e) => FraudDetector.analyze(e, all).level != RiskLevel.safe).toList();
    } else {
      list = all.where((e) {
        final hay = '${e.name ?? ''} ${e.number ?? ''}'.toLowerCase();
        if (!hay.contains(query.toLowerCase())) return false;
        return switch (filter) {
          _Filter.incoming => e.callType == CallType.incoming,
          _Filter.outgoing => e.callType == CallType.outgoing,
          _Filter.missed => e.callType == CallType.missed,
          _ => true,
        };
      }).toList();
    }
    setState(() => filtered = list);
  }

  Future<void> _blockNumber(String? number, {bool unblock = false}) async {
    if (number == null) return;
    final prefs = await SharedPreferences.getInstance();
    HapticFeedback.mediumImpact();
    if (unblock) blocked.remove(number); else { blocked.add(number); all.removeWhere((e) => e.number == number); }
    await prefs.setStringList('blocked', blocked.toList());
    _apply();
  }

  Future<void> _directCall(String number) async {
    try {
      await FlutterPhoneDirectCaller.callNumber(number);
    } catch (_) {
      final uri = Uri.parse('tel:$number');
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  Future<void> _sendSms(String number) async {
    final uri = Uri.parse('sms:$number');
    if (await canLaunchUrl(uri)) await launchUrl(uri); else _toast('فتح الرسائل...');
  }

  Color _colorOf(String? s) => K.gradients[(s ?? '0').hashCode.abs() % K.gradients.length][0];
  String _fmtShort(int? sec) { if (sec == null || sec <= 0) return '—'; if (sec < 60) return '${sec}ث'; if (sec < 3600) return '${(sec / 60).round()}د'; return '${(sec / 3600).toStringAsFixed(1)}س'; }
  String _fmtDate(int? ts) { if (ts == null) return ''; final d = DateTime.fromMillisecondsSinceEpoch(ts); String two(int v) => v.toString().padLeft(2, '0'); return '${two(d.hour)}:${two(d.minute)} • ${d.day}/${d.month}'; }
  String _dayKey(int? ts) { final d = DateTime.fromMillisecondsSinceEpoch(ts ?? 0); final now = DateTime.now(); if (d.year == now.year && d.month == now.month && d.day == now.day) return 'اليوم'; if (d.year == now.year && d.month == now.month && d.day == now.day - 1) return 'أمس'; return '${d.day}/${d.month}'; }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, backgroundColor: const Color(0xFF1A1A2E), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        _AnimatedBackground(ctrl: bgCtrl),
        SafeArea(child: loading ? const _LoadingView() : !hasPermission ? _PermissionView(onRequest: _load) : _buildBody()),
      ]),
      bottomNavigationBar: _buildBottomNav(),
      floatingActionButton: _tab == 0 ? _buildFAB() : null,
    );
  }

  Widget _buildBody() {
    switch (_tab) {
      case 1: return _buildDialer();
      case 2: return _buildRecordingsTab();
      case 3: return _buildShieldTab();
      default: return RefreshIndicator(onRefresh: _load, color: K.primary, child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [_buildHeader(), SliverPersistentHeader(pinned: true, delegate: _StickyDelegate(height: 118, child: Column(children: [_buildSearch(), const SizedBox(height: 8), _buildChips()]))), if (_analyticsTab == 0) _buildAnalytics() else _buildTopContacts(), _buildList(), const SliverToBoxAdapter(child: SizedBox(height: 110))]));
    }
  }

  Widget _buildHeader() {
    final fraudCount = all.where((e) => FraudDetector.analyze(e, all).level.index >= 2).length;
    return SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 4), child: FadeTransition(opacity: enterCtrl, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(gradient: const LinearGradient(colors: [K.primary, K.teal]), borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: K.primary.withOpacity(0.4), blurRadius: 16)]), child: const Text('ULTRA • PRO SHIELD 2027', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10.5, letterSpacing: 1.2, color: Colors.white))),
        const Spacer(),
        if (fraudCount > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: K.red, borderRadius: BorderRadius.circular(8)), child: Text('⚠️ $fraudCount خطر', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white))),
        const SizedBox(width: 8),
        _GlassIcon(icon: Icons.shield_rounded, onTap: () => setState(() => _tab = 3)),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        _StatCard(label: 'الإجمالي', value: '${all.length}', icon: Icons.layers_rounded, gradient: K.gradients[0], pulse: pulseCtrl),
        const SizedBox(width: 8),
        _StatCard(label: 'محظور', value: '${blocked.length}', icon: Icons.block_rounded, gradient: [K.red, K.pink], pulse: pulseCtrl),
        const SizedBox(width: 8),
        _StatCard(label: 'احتيال', value: '$fraudCount', icon: Icons.warning_rounded, gradient: [K.amber, K.red], pulse: pulseCtrl),
        const SizedBox(width: 8),
        _StatCard(label: 'تسجيلات', value: '${recordings.length}', icon: Icons.mic_rounded, gradient: K.gradients[4], pulse: pulseCtrl),
      ]),
    ]))));
  }

  Widget _buildSearch() => Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ClipRRect(borderRadius: BorderRadius.circular(18), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(18), border: Border.all(color: query.isNotEmpty ? K.primary.withOpacity(0.6) : Colors.white.withOpacity(0.12))), child: TextField(controller: _searchCtrl, onChanged: (v) { query = v; _apply(); }, textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 14), decoration: InputDecoration(hintText: 'ابحث بالاسم أو الرقم...', hintStyle: const TextStyle(color: Colors.white38, fontSize: 13), prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54, size: 20), suffixIcon: query.isNotEmpty ? IconButton(icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white54), onPressed: () { _searchCtrl.clear(); query = ''; _apply(); }) : null, border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13)))))));

  Widget _buildChips() {
    final items = [('الكل', _Filter.all, Icons.all_inclusive_rounded), ('وارد', _Filter.incoming, Icons.call_received_rounded), ('صادر', _Filter.outgoing, Icons.call_made_rounded), ('فائت', _Filter.missed, Icons.call_missed_rounded), ('🚨 احتيال', _Filter.fraud, Icons.shield_rounded), ('المحظور', _Filter.blocked, Icons.block_rounded)];
    final tabs = [(0, '📈 التحليلات'), (1, '🏆 الأكثر')];
    return Container(color: K.bg.withOpacity(0.75), child: Column(children: [
      SizedBox(height: 44, child: ListView.separated(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (_, i) { final (label, f, icon) = items[i]; final sel = filter == f; return FilterChip(selected: sel, showCheckmark: false, label: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 13, color: sel ? Colors.white : Colors.white54), const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: 12, color: sel ? Colors.white : Colors.white70, fontWeight: sel ? FontWeight.bold : FontWeight.normal))]), selectedColor: f == _Filter.fraud ? K.red.withOpacity(0.9) : f == _Filter.missed ? K.red.withOpacity(0.85) : f == _Filter.blocked ? Colors.black45 : K.primary, backgroundColor: Colors.white.withOpacity(0.07), side: BorderSide(color: sel ? Colors.transparent : Colors.white.withOpacity(0.1)), onSelected: (_) { HapticFeedback.selectionClick(); setState(() => filter = f); _apply(); }); })),
      const SizedBox(height: 4),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(14)), child: Row(children: [for (final entry in tabs.asMap().entries) Expanded(child: GestureDetector(onTap: () { HapticFeedback.selectionClick(); setState(() => _analyticsTab = entry.value.$1); }, child: AnimatedContainer(duration: const Duration(milliseconds: 250), padding: const EdgeInsets.symmetric(vertical: 9), decoration: BoxDecoration(gradient: _analyticsTab == entry.value.$1 ? const LinearGradient(colors: [K.primary, Color(0xFF4834D4)]) : null, borderRadius: BorderRadius.circular(11)), child: Text(entry.value.$2, textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, fontWeight: _analyticsTab == entry.value.$1 ? FontWeight.bold : FontWeight.normal, color: _analyticsTab == entry.value.$1 ? Colors.white : Colors.white54)))))]))),
    ]));
  }

  Widget _buildAnalytics() {
    final week = List.generate(7, (i) { final day = DateTime.now().subtract(Duration(days: 6 - i)); return all.where((e) { final d = DateTime.fromMillisecondsSinceEpoch(e.timestamp ?? 0); return d.year == day.year && d.month == day.month && d.day == day.day; }).length; });
    final max = week.reduce(math.max).clamp(1, 1 << 30);
    return SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 4), child: ClipRRect(borderRadius: BorderRadius.circular(24), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white.withOpacity(0.09))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Row(children: [Icon(Icons.insights_rounded, color: K.teal, size: 18), SizedBox(width: 6), Text('نشاط ٧ أيام + حماية', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5))]), const SizedBox(height: 14), SizedBox(height: 110, child: CustomPaint(painter: _BarChartPainter(week, max), size: Size.infinite))]))))));
  }

  Widget _buildTopContacts() {
    final map = <String, int>{}; for (final e in all) { final k = e.name?.isNotEmpty == true ? e.name! : (e.number ?? 'مجهول'); map[k] = (map[k] ?? 0) + 1; }
    final top = map.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    final top5 = top.take(5).toList();
    return SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 4), child: ClipRRect(borderRadius: BorderRadius.circular(24), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white.withOpacity(0.09))), child: Column(children: [for (final e in top5.asMap().entries) ListTile(leading: CircleAvatar(backgroundColor: _colorOf(e.value.key), child: Text(e.value.key[0])), title: Text(e.value.key, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)), trailing: Text('${e.value.value}'))]))))));
  }

  Widget _buildList() {
    if (filtered.isEmpty) return SliverFillRemaining(hasScrollBody: false, child: Center(child: Text(filter == _Filter.fraud ? 'لا يوجد احتيال مكتشف ✅' : 'لا توجد نتائج', style: const TextStyle(color: Colors.white38))));
    final groups = <String, List<CallLogEntry>>{}; final order = <String>[]; for (final e in filtered) { final k = _dayKey(e.timestamp); if (!groups.containsKey(k)) { groups[k] = []; order.add(k); } groups[k]!.add(e); }
    final widgets = <Widget>[]; for (final day in order) { widgets.add(Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8), child: Text(day, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFFB8B0F0))))); widgets.addAll(groups[day]!.map((e) => _buildCard(e))); }
    return SliverList(delegate: SliverChildListDelegate(widgets));
  }

  Widget _buildCard(CallLogEntry e) {
    final fraud = FraudDetector.analyze(e, all);
    final col = _colorOf(e.number);
    final isMissed = e.callType == CallType.missed;
    final typeColor = fraud.level == RiskLevel.critical ? K.red : fraud.level == RiskLevel.fraud ? K.amber : isMissed ? K.red : K.green;
    return Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 10), child: ClipRRect(borderRadius: BorderRadius.circular(22), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: Container(decoration: BoxDecoration(color: fraud.level.index >= 2 ? K.red.withOpacity(0.12) : Colors.white.withOpacity(0.055), borderRadius: BorderRadius.circular(22), border: Border.all(color: fraud.level.index >= 2 ? K.red.withOpacity(0.4) : Colors.white.withOpacity(0.09))), child: ListTile(
      leading: Stack(children: [Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [col, col.withOpacity(0.6)])), child: Center(child: Text((e.name?.isNotEmpty == true ? e.name![0] : e.number?.substring(e.number!.length - 2) ?? '?'), style: const TextStyle(fontWeight: FontWeight.w900)))), if (fraud.level.index >= 2) Positioned(right: 0, bottom: 0, child: Container(padding: const EdgeInsets.all(3), decoration: const BoxDecoration(color: K.red, shape: BoxShape.circle), child: const Icon(Icons.warning_rounded, size: 10, color: Colors.white)))]),
      title: Row(children: [Expanded(child: Text(e.name?.isNotEmpty == true ? e.name! : 'مجهول', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)), if (fraud.level.index >= 2) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: fraud.level == RiskLevel.critical ? K.red : K.amber, borderRadius: BorderRadius.circular(6)), child: Text(fraud.level == RiskLevel.critical ? 'احتيال' : 'مشبوه', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)))]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e.number ?? '', style: const TextStyle(fontSize: 12, color: Colors.white54)), const SizedBox(height: 2), Text(fraud.level != RiskLevel.safe ? '⚠️ ${fraud.reason} (${fraud.score}%)' : _fmtDate(e.timestamp), style: TextStyle(fontSize: 10, color: fraud.level != RiskLevel.safe ? K.amber : Colors.white24))]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.call_rounded, color: K.green, size: 20), onPressed: () => _directCall(e.number ?? '')),
        IconButton(icon: const Icon(Icons.message_rounded, color: K.blue, size: 18), onPressed: () => _sendSms(e.number ?? '')),
        IconButton(icon: const Icon(Icons.more_horiz_rounded, color: Colors.white38, size: 18), onPressed: () => _showOptions(e)),
      ]),
    )))));
  }

  Widget _buildDialer() {
    return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      const SizedBox(height: 20),
      ClipRRect(borderRadius: BorderRadius.circular(18), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(18)), child: TextField(controller: _dialCtrl, textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, letterSpacing: 3, fontWeight: FontWeight.w800), keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: '0', border: InputBorder.none))))),
      const SizedBox(height: 20),
      Expanded(child: GridView.count(crossAxisCount: 3, childAspectRatio: 1.3, children: [for (final n in ['1','2','3','4','5','6','7','8','9','*','0','#']) _dialBtn(n)])),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        FloatingActionButton(backgroundColor: K.green, onPressed: () { if (_dialCtrl.text.isNotEmpty) _directCall(_dialCtrl.text); }, child: const Icon(Icons.call_rounded, color: Colors.white, size: 32)),
        const SizedBox(width: 20),
        FloatingActionButton.small(backgroundColor: Colors.white12, onPressed: () { if (_dialCtrl.text.isNotEmpty) setState(() => _dialCtrl.text = _dialCtrl.text.substring(0, _dialCtrl.text.length - 1)); }, child: const Icon(Icons.backspace_rounded)),
      ]),
      const SizedBox(height: 20),
    ]));
  }

  Widget _dialBtn(String n) => InkWell(borderRadius: BorderRadius.circular(20), onTap: () { HapticFeedback.selectionClick(); setState(() => _dialCtrl.text += n); }, child: Container(margin: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(20)), child: Center(child: Text(n, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)))));

  Widget _buildRecordingsTab() {
    return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      const SizedBox(height: 10),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: _isRecording ? K.red.withOpacity(0.15) : Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(24), border: Border.all(color: _isRecording ? K.red.withOpacity(0.5) : Colors.white10)), child: Column(children: [
        Icon(Icons.mic_rounded, size: 48, color: _isRecording ? K.red : Colors.white38),
        const SizedBox(height: 8),
        Text(_isRecording ? 'جاري التسجيل...' : 'تسجيل المكالمات', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        const SizedBox(height: 4),
        const Text('سيتم حفظ التسجيلات محلياً بشكل مشفر وآمن', style: TextStyle(fontSize: 11, color: Colors.white38), textAlign: TextAlign.center),
        const SizedBox(height: 14),
        FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: _isRecording ? K.red : K.primary, padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), onPressed: _toggleRecord, icon: Icon(_isRecording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded), label: Text(_isRecording ? 'إيقاف وحفظ' : 'بدء تسجيل جديد')),
      ])),
      const SizedBox(height: 16),
      Expanded(child: recordings.isEmpty ? const Center(child: Text('لا توجد تسجيلات', style: TextStyle(color: Colors.white24))) : ListView.builder(itemCount: recordings.length, itemBuilder: (_, i) { final f = recordings[i]; final name = f.path.split('/').last; return ListTile(leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: K.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.audio_file_rounded, color: K.primary)), title: Text(name, style: const TextStyle(fontSize: 12)), subtitle: Text('${(File(f.path).lengthSync() / 1024).toStringAsFixed(1)} KB', style: const TextStyle(fontSize: 10, color: Colors.white38)), trailing: IconButton(icon: const Icon(Icons.play_arrow_rounded), onPressed: () async { try { await _player.setFilePath(f.path); _player.play(); } catch (_) {} }),); })),
    ]));
  }

  Widget _buildShieldTab() {
    final frauds = all.where((e) => FraudDetector.analyze(e, all).level.index >= 1).toList();
    final critical = frauds.where((e) => FraudDetector.analyze(e, all).level == RiskLevel.critical).length;
    return Padding(padding: const EdgeInsets.all(16), child: ListView(children: [
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF6C5CE7), Color(0xFF00CEC9)]), borderRadius: BorderRadius.circular(24)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Row(children: [Icon(Icons.shield_rounded, color: Colors.white, size: 28), SizedBox(width: 8), Text('مركز الحماية الذكي', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.white))]), const SizedBox(height: 8), Text('نظام كشف احتيال متقدم يحلل ${all.length} مكالمة ويحميك من الأرقام المشبوهة', style: const TextStyle(color: Colors.white70, fontSize: 12)), const SizedBox(height: 16), Row(children: [Expanded(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(14)), child: Column(children: [Text('$critical', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)), const Text('خطر عالي', style: TextStyle(fontSize: 10, color: Colors.white70))]))), const SizedBox(width: 8), Expanded(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(14)), child: Column(children: [Text('${frauds.length}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)), const Text('مشبوه', style: TextStyle(fontSize: 10, color: Colors.white70))]))), const SizedBox(width: 8), Expanded(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(14)), child: Column(children: [Text('${blocked.length}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)), const Text('محظور', style: TextStyle(fontSize: 10, color: Colors.white70))]))),])])),
      const SizedBox(height: 16),
      const Text('قواعد الحماية النشطة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      const SizedBox(height: 8),
      _shieldRule(Icons.block_rounded, K.red, 'حظر تلقائي للأرقام الاحتيالية', 'يتم حظر أي رقم يتجاوز 80% خطورة تلقائياً', true),
      _shieldRule(Icons.notifications_off_rounded, K.amber, 'كتم مكالمات السبام', 'عدم إزعاج من الأرقام المشبوهة', true),
      _shieldRule(Icons.record_voice_over_rounded, K.teal, 'تسجيل تلقائي للأرقام المجهولة', 'تسجيل أي مكالمة من رقم غير محفوظ', false),
      _shieldRule(Icons.security_rounded, K.green, 'تشفير السجلات', 'حفظ السجلات مشفرة محلياً', true),
      const SizedBox(height: 16),
      if (frauds.isNotEmpty) ...[const Text('أخطر الأرقام المكتشفة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), const SizedBox(height: 8), ...frauds.take(5).map((e) { final f = FraudDetector.analyze(e, all); return Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: K.red.withOpacity(0.3))), child: Row(children: [Container(padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: K.red, shape: BoxShape.circle), child: const Icon(Icons.warning_rounded, size: 14, color: Colors.white)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e.number ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)), Text(f.reason, style: const TextStyle(fontSize: 11, color: Colors.white54))])), Text('${f.score}%', style: const TextStyle(color: K.red, fontWeight: FontWeight.w900)), const SizedBox(width: 8), FilledButton(style: FilledButton.styleFrom(backgroundColor: K.red, minimumSize: const Size(0, 32)), onPressed: () => _blockNumber(e.number), child: const Text('حظر', style: TextStyle(fontSize: 11)))])); })],
    ]));
  }

  Widget _shieldRule(IconData ic, Color c, String t, String d, bool on) => Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(14)), child: Row(children: [Container(padding: const EdgeInsets.all(7), decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(9)), child: Icon(ic, color: c, size: 16)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)), Text(d, style: const TextStyle(fontSize: 10.5, color: Colors.white38))])), Switch(value: on, activeColor: K.primary, onChanged: (_) {})]));

  Widget _buildBottomNav() => ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: BottomNavigationBar(currentIndex: _tab, onTap: (i) { HapticFeedback.selectionClick(); setState(() => _tab = i); if (i == 2) _loadRecordings(); }, backgroundColor: const Color(0xFF12121E).withOpacity(0.9), selectedItemColor: K.primary, unselectedItemColor: Colors.white38, type: BottomNavigationBarType.fixed, selectedFontSize: 10, unselectedFontSize: 9, items: const [BottomNavigationBarItem(icon: Icon(Icons.call_rounded), label: 'السجل'), BottomNavigationBarItem(icon: Icon(Icons.dialpad_rounded), label: 'اتصال'), BottomNavigationBarItem(icon: Icon(Icons.mic_rounded), label: 'تسجيل'), BottomNavigationBarItem(icon: Icon(Icons.shield_rounded), label: 'حماية')])));

  Widget _buildFAB() => AnimatedBuilder(animation: pulseCtrl, builder: (_, __) => Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: K.primary.withOpacity(0.25 + pulseCtrl.value * 0.3), blurRadius: 20)]), child: FloatingActionButton.extended(backgroundColor: K.primary, elevation: 0, onPressed: _load, icon: const Icon(Icons.refresh_rounded, color: Colors.white), label: const Text('تحديث فوري', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)))));

  void _showOptions(CallLogEntry e) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF12121E), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))), builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 42, height: 4.5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3))),
      const SizedBox(height: 14),
      Text(e.number ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
      const SizedBox(height: 14),
      _opt(Icons.call_rounded, K.green, 'اتصال مباشر PRO', () { Navigator.pop(context); _directCall(e.number ?? ''); }),
      _opt(Icons.message_rounded, K.blue, 'إرسال SMS', () { Navigator.pop(context); _sendSms(e.number ?? ''); }),
      _opt(Icons.mic_rounded, K.teal, 'تسجيل هذه المكالمة', () { Navigator.pop(context); _toggleRecord(); }),
      _opt(Icons.shield_rounded, K.amber, 'فحص احتيال', () { Navigator.pop(context); final f = FraudDetector.analyze(e, all); _toast('${f.level.name} - ${f.reason} (${f.score}%)'); }),
      _opt(Icons.block_rounded, K.red, 'حظر نهائي 🚫', () async { Navigator.pop(context); await _blockNumber(e.number); }, destructive: true),
    ]))));
  }

  Widget _opt(IconData ic, Color c, String t, VoidCallback tap, {bool destructive = false}) => Padding(padding: const EdgeInsets.only(bottom: 8), child: ListTile(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), tileColor: Colors.white.withOpacity(0.04), leading: Container(padding: const EdgeInsets.all(7), decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(10)), child: Icon(ic, color: c, size: 18)), title: Text(t, style: TextStyle(color: destructive ? K.red : Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)), onTap: tap));
}

class _AnimatedBackground extends StatelessWidget {
  final AnimationController ctrl; const _AnimatedBackground({required this.ctrl});
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: ctrl, builder: (_, __) { final t = ctrl.value; return Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment(math.cos(t * 2 * math.pi), math.sin(t * 2 * math.pi)), end: Alignment(-math.cos(t * 2 * math.pi), -math.sin(t * 2 * math.pi)), colors: const [Color(0xFF0F0C29), Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F0C29)])), child: Stack(children: [Positioned(top: 60 + 30 * math.sin(t * 2 * math.pi), left: 30 + 20 * math.cos(t * 2 * math.pi), child: _orb(const Color(0xFF6C5CE7), 130, 0.14)), Positioned(bottom: 100 + 40 * math.cos(t * 2 * math.pi), right: 20 + 25 * math.sin(t * 2 * math.pi), child: _orb(const Color(0xFF00CEC9), 100, 0.10))])) ; }); Widget _orb(Color c, double d, double o) => Container(width: d, height: d, decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: c.withOpacity(o), blurRadius: 90, spreadRadius: 20)]));
}
class _StatCard extends StatelessWidget {
  final String label, value; final IconData icon; final List<Color> gradient; final AnimationController pulse;
  const _StatCard({required this.label, required this.value, required this.icon, required this.gradient, required this.pulse});
  @override Widget build(BuildContext context) => Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.1))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(padding: const EdgeInsets.all(5), decoration: BoxDecoration(gradient: LinearGradient(colors: gradient), borderRadius: BorderRadius.circular(9)), child: Icon(icon, size: 13, color: Colors.white)), const SizedBox(height: 6), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)), Text(label, style: const TextStyle(fontSize: 9, color: Colors.white54))])))));
}
class _GlassIcon extends StatelessWidget { final IconData icon; final VoidCallback onTap; const _GlassIcon({required this.icon, required this.onTap}); @override Widget build(BuildContext context) => InkWell(borderRadius: BorderRadius.circular(13), onTap: onTap, child: ClipRRect(borderRadius: BorderRadius.circular(13), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: Container(padding: const EdgeInsets.all(9), decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(13)), child: Icon(icon, size: 18))))); }
class _LoadingView extends StatelessWidget { const _LoadingView(); @override Widget build(BuildContext context) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.shield_rounded, size: 52, color: K.primary), const SizedBox(height: 12), const Text('ULTRA PRO SHIELD - جاري الفحص الأمني...', style: TextStyle(color: Colors.white38, fontSize: 12)), const SizedBox(height: 12), const SizedBox(width: 120, child: LinearProgressIndicator(minHeight: 3, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(K.primary)))])); }
class _PermissionView extends StatelessWidget { final VoidCallback onRequest; const _PermissionView({required this.onRequest}); @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(color: K.primary.withOpacity(0.15), shape: BoxShape.circle), child: const Icon(Icons.security_rounded, size: 48, color: K.primary)), const SizedBox(height: 18), const Text('صلاحيات الحماية الكاملة مطلوبة', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18), textAlign: TextAlign.center), const SizedBox(height: 8), const Text('يحتاج التطبيق لجميع الصلاحيات: سجل المكالمات، الاتصال المباشر، الرسائل، الميكروفون للتسجيل، وكشف الاحتيال. كل بياناتك محمية ومشفرة محلياً.', style: TextStyle(color: Colors.white54, fontSize: 12.5), textAlign: TextAlign.center), const SizedBox(height: 22), FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: K.primary, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: onRequest, icon: const Icon(Icons.verified_user_rounded), label: const Text('تفعيل الحماية الكاملة'))]))); }
class _BarChartPainter extends CustomPainter { final List<int> data; final int max; _BarChartPainter(this.data, this.max); @override void paint(Canvas canvas, Size size) { final barW = size.width / (data.length * 1.8); final gap = (size.width - barW * data.length) / (data.length + 1); final colors = [K.teal, K.blue, K.primary, K.pink, K.amber, K.green, K.red]; for (var i = 0; i < data.length; i++) { final h = data[i] == 0 ? 4.0 : (data[i] / max) * (size.height - 28); final x = gap + i * (barW + gap); final y = size.height - 22 - h; final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, barW, h), const Radius.circular(6)); final paint = Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors[i], colors[i].withOpacity(0.35)]).createShader(Rect.fromLTWH(x, y, barW, h)); canvas.drawRRect(r, paint); } } @override bool shouldRepaint(covariant _BarChartPainter oldDelegate) => oldDelegate.data != data; }
class _StickyDelegate extends SliverPersistentHeaderDelegate { final Widget child; final double height; _StickyDelegate({required this.child, required this.height}); @override double get minExtent => height; @override double get maxExtent => height; @override Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child; @override bool shouldRebuild(covariant _StickyDelegate oldDelegate) => child != oldDelegate.child; }