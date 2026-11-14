import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'main.dart';
import 'search.dart';

const repo = 'yoyo-ui/cambridge-offline';
const packsSql = 'CREATE TABLE packs(lang TEXT PRIMARY KEY, n INTEGER, audio INTEGER)';
final navKey = GlobalKey<NavigatorState>();

class Pack extends ChangeNotifier {
  int done = 0, total = 0;
  bool running = false, stop = false;
  void ping() => notifyListeners();
}

final packs = {for (final k in langs.keys) k: Pack()};

Future<bool> offline() async => (await Connectivity().checkConnectivity()).contains(ConnectivityResult.none);

Future<List<String>> wordList({bool refresh = false}) async {
  final f = File(p.join((await getApplicationDocumentsDirectory()).path, 'words.txt'));
  if (refresh || !f.existsSync()) {
    try {
      final r = await http.get(Uri.parse('https://raw.githubusercontent.com/$repo/main/words.txt')).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && r.bodyBytes.length > 100) await f.writeAsBytes(r.bodyBytes);
    } catch (_) {}
  }
  if (!f.existsSync()) return [];
  return f.readAsLinesSync().map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
}

Future<void> runPack(String lg, int n, bool audio, {bool refresh = false}) async {
  final pk = packs[lg]!;
  if (pk.running) return;
  pk.running = true;
  pk.stop = false;
  pk.done = 0;
  pk.total = 0;
  pk.ping();
  try {
    final words = (await wordList(refresh: refresh)).take(n).toList();
    final have = (await db.query('words', columns: ['word'], where: 'lang=?', whereArgs: [lg])).map((e) => e['word'] as String).toSet();
    final todo = words.where((w) => !have.contains(w)).toList();
    pk.total = todo.length;
    pk.ping();
    await db.insert('packs', {'lang': lg, 'n': n, 'audio': audio ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
    var i = 0;
    Future<void> worker() async {
      while (!pk.stop && i < todo.length) {
        final w = todo[i++];
        try {
          final r = await http.get(Uri.parse('$api/$lg/${Uri.encodeComponent(w)}')).timeout(const Duration(seconds: 20));
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (r.statusCode == 200 && j is Map && j['word'] != null) {
            await db.insert('words', {'key': '$lg:$w', 'word': w, 'lang': lg, 'json': jsonEncode(j), 'ts': 0, 'fav': 0, 'seen': 0},
                conflictAlgorithm: ConflictAlgorithm.ignore);
            if (audio) await saveAudio(j);
          }
        } catch (_) {
          if (await offline()) pk.stop = true;
        }
        pk.done++;
        if (pk.done % 5 == 0) pk.ping();
      }
    }

    await Future.wait([worker(), worker(), worker()]);
  } catch (_) {}
  pk.running = false;
  pk.ping();
}

Future<void> deletePack(String lg) async {
  packs[lg]!.stop = true;
  await db.delete('words', where: 'lang=? AND seen=0 AND fav=0', whereArgs: [lg]);
  await db.delete('packs', where: 'lang=?', whereArgs: [lg]);
  for (final f in audioDir.listSync()) {
    try {
      f.deleteSync();
    } catch (_) {}
  }
}

DateTime? _lastSync;
Future<void> autoSync() async {
  final now = DateTime.now();
  if (_lastSync != null && now.difference(_lastSync!) < const Duration(minutes: 10)) return;
  if (await offline()) return;
  final rows = await db.query('packs');
  if (rows.isEmpty) return;
  _lastSync = now;
  await wordList(refresh: true);
  for (final r in rows) {
    await runPack(r['lang'] as String, r['n'] as int, r['audio'] == 1);
  }
  await loadVocab();
}

Future<void> checkUpdate({bool manual = false}) async {
  final ctx = navKey.currentContext;
  if (ctx == null) return;
  void toast(String m) => ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(m)));
  try {
    final r = await http.get(Uri.parse('https://api.github.com/repos/$repo/releases/latest')).timeout(const Duration(seconds: 15));
    final j = jsonDecode(r.body);
    final latest = int.tryParse(s(j['tag_name']).replaceAll('v', '')) ?? 0;
    final cur = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    final url = (j['assets'] as List? ?? []).whereType<Map>().map((a) => s(a['browser_download_url'])).where((u) => u.endsWith('.apk')).firstOrNull;
    if (latest <= cur || url == null) {
      if (manual) toast('أنت على آخر إصدار ✓');
      return;
    }
    final go = await showDialog<bool>(
      context: ctx,
      useRootNavigator: false,
      builder: (d) => AlertDialog(
        title: Text('فيه تحديث جديد (v$latest)'),
        content: const Text('تحب تنزّله وتثبّته دلوقتي؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('بعدين')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('حدّث')),
        ],
      ),
    );
    if (go != true) return;
    final prog = ValueNotifier<double?>(null);
    showDialog(
      context: ctx,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (_) => AlertDialog(
        title: const Text('بنحمّل التحديث...'),
        content: ValueListenableBuilder<double?>(valueListenable: prog, builder: (_, v, __) => LinearProgressIndicator(value: v)),
      ),
    );
    try {
      final res = await http.Client().send(http.Request('GET', Uri.parse(url)));
      final total = res.contentLength ?? 0;
      final f = File(p.join((await getTemporaryDirectory()).path, 'update.apk'));
      final sink = f.openWrite();
      var got = 0;
      await for (final ch in res.stream) {
        sink.add(ch);
        got += ch.length;
        if (total > 0) prog.value = got / total;
      }
      await sink.close();
      navKey.currentState?.pop();
      await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    } catch (_) {
      navKey.currentState?.pop();
      toast('فشل تحميل التحديث، جرّب تاني');
    }
  } catch (_) {
    if (manual) toast('مفيش نت أو GitHub مش بيرد');
  }
}

void startServices() {
  loadVocab();
  Future.delayed(const Duration(seconds: 3), () {
    checkUpdate();
    autoSync();
  });
  Connectivity().onConnectivityChanged.listen((r) {
    if (!r.contains(ConnectivityResult.none)) autoSync();
  });
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});
  @override
  State<DownloadsPage> createState() => _DlState();
}

class _DlState extends State<DownloadsPage> {
  bool audio = false;
  Future<Map<String, List<int>>> stats() async {
    final r = await db.rawQuery('SELECT lang, COUNT(*) c, SUM(LENGTH(json)) b FROM words GROUP BY lang');
    return {for (final x in r) '${x['lang']}': [x['c'] as int, (x['b'] as int?) ?? 0]};
  }

  String mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';
  int audioBytes() => audioDir.listSync().whereType<File>().fold(0, (a, f) => a + f.lengthSync());

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge(packs.values.toList()),
        builder: (_, __) => FutureBuilder<Map<String, List<int>>>(
          future: stats(),
          builder: (c, snap) {
            final st = snap.data ?? {};
            final t = Theme.of(c).textTheme;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.system_update),
                  title: const Text('التحديث التلقائي'),
                  subtitle: const Text('بيدوّر على إصدار جديد كل ما تفتح الأب وفي نت'),
                  trailing: TextButton(onPressed: () => checkUpdate(manual: true), child: const Text('دوّر دلوقتي')),
                ),
              ),
              SwitchListTile(
                title: const Text('حمّل الصوت مع الكلمات'),
                subtitle: Text('مساحة أكبر. الصوت المحفوظ حاليًا: ${mb(audioBytes())}'),
                value: audio,
                onChanged: (v) => setState(() => audio = v),
              ),
              for (final e in langs.entries) _card(e.key, e.value, st[e.key] ?? [0, 0], t),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('الأب بيدوّر على كلمات جديدة للقواميس المحمّلة كل ما يلاقي نت، والتحميل بيكمّل لوحده من حيث وقف. لازم الأب يكون مفتوح.'),
              ),
            ]);
          },
        ),
      );

  Widget _card(String lg, String name, List<int> st, TextTheme t) {
    final pk = packs[lg]!;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(name, style: t.titleMedium)),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async {
              await deletePack(lg);
              setState(() {});
            }),
          ]),
          Text('${st[0]} كلمة محفوظة · ${mb(st[1])}'),
          if (pk.running) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pk.total == 0 ? null : pk.done / pk.total),
            Text('${pk.done} / ${pk.total}'),
            TextButton(onPressed: () => pk.stop = true, child: const Text('إيقاف مؤقت')),
          ] else
            Wrap(spacing: 8, children: [
              for (final n in [1000, 3000, 5000, 100000])
                OutlinedButton(onPressed: () => runPack(lg, n, audio), child: Text(n > 5000 ? 'الكل' : '$n كلمة')),
            ]),
        ]),
      ),
    );
  }
}
