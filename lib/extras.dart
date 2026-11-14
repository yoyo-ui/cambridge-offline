import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'main.dart';
import 'search.dart';

const repo = 'yoyo-ui/cambridge-offline';
const missingSql = 'CREATE TABLE missing(key TEXT PRIMARY KEY, ts INTEGER)';
const packsSql = 'CREATE TABLE packs(lang TEXT PRIMARY KEY, n INTEGER, audio INTEGER)';
final navKey = GlobalKey<NavigatorState>();

class Pack extends ChangeNotifier {
  int done = 0, total = 0;
  bool running = false, stop = false;
  String err = '';
  void ping() => notifyListeners();
}

final packs = {for (final k in langs.keys) k: Pack()};

Future<bool> offline() async => (await Connectivity().checkConnectivity()).contains(ConnectivityResult.none);

Future<List<String>> wordList({bool refresh = false}) async {
  final dir = (await getApplicationDocumentsDirectory()).path;
  final f = File(p.join(dir, 'words.txt'));
  final tag = File(p.join(dir, 'words.etag'));
  if (refresh || !f.existsSync()) {
    try {
      final r = await http.get(Uri.parse('https://raw.githubusercontent.com/$repo/main/words.txt'), headers: {
        if (f.existsSync() && tag.existsSync()) 'If-None-Match': tag.readAsStringSync(),
      }).timeout(const Duration(seconds: 40));
      if (r.statusCode == 200 && r.bodyBytes.length > 100) {
        await f.writeAsBytes(r.bodyBytes);
        final t = r.headers['etag'];
        if (t != null) await tag.writeAsString(t);
      }
    } catch (_) {}
  }
  if (!f.existsSync()) return [];
  return f.readAsLinesSync().map((x) => x.trim().toLowerCase()).where((x) => x.isNotEmpty).toList();
}

const _ch = MethodChannel('cambridge/dl');
Future<void> svc(String m, [String text = '']) async {
  try {
    await _ch.invokeMethod(m, {'text': text});
  } catch (_) {}
}

int _active = 0;

Future<void> runPack(String lg, int n, bool audio) async {
  final pk = packs[lg]!;
  if (pk.running) return;
  pk.running = true;
  pk.stop = false;
  pk.done = 0;
  pk.total = 0;
  pk.err = '';
  pk.ping();
  if (_active++ == 0) await svc('start', 'بنحمّل القواميس...');
  try {
    final words = (await wordList(refresh: true)).take(n).toList();
    final have = (await db.query('words', columns: ['word'], where: 'lang=?', whereArgs: [lg])).map((x) => x['word'] as String).toSet();
    final cut = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final miss = (await db.query('missing', columns: ['key'], where: 'ts>?', whereArgs: [cut])).map((x) => x['key'] as String).toSet();
    final todo = words.where((w) => !have.contains(w) && !miss.contains('$lg:$w')).toList();
    pk.total = todo.length;
    pk.ping();
    await db.insert('packs', {'lang': lg, 'n': n, 'audio': audio ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
    var i = 0, fails = 0;
    Future<void> worker() async {
      while (!pk.stop && i < todo.length) {
        final w = todo[i++];
        var ok = false;
        for (var a = 0; a < 3 && !pk.stop; a++) {
          try {
            final r = await http.get(Uri.parse('$api/$lg/${Uri.encodeComponent(w)}')).timeout(const Duration(seconds: 25));
            if (r.statusCode == 429 || r.statusCode >= 500) throw Exception('busy');
            dynamic j;
            try {
              j = jsonDecode(utf8.decode(r.bodyBytes));
            } catch (_) {}
            final now = DateTime.now().millisecondsSinceEpoch;
            if (r.statusCode == 200 && j is Map && j['word'] != null) {
              await db.insert('words', {'key': '$lg:$w', 'word': w, 'lang': lg, 'json': enc(j), 'ts': 0, 'fav': 0, 'seen': 0},
                  conflictAlgorithm: ConflictAlgorithm.ignore);
              addVocab(w);
              if (audio) await saveAudio(j);
            } else {
              await db.insert('missing', {'key': '$lg:$w', 'ts': now}, conflictAlgorithm: ConflictAlgorithm.replace);
            }
            ok = true;
            fails = 0;
            break;
          } catch (_) {
            if (await offline()) {
              pk.err = 'مفيش نت، هنكمّل لما يرجع';
              pk.stop = true;
            } else {
              await Future.delayed(Duration(seconds: 2 + a * 3));
            }
          }
        }
        if (!ok && !pk.stop && ++fails >= 6) {
          pk.err = 'السيرفر مش بيرد، هنكمّل بعدين';
          pk.stop = true;
        }
        pk.done++;
        if (pk.done % 20 == 0) {
          pk.ping();
          svc('update', '${langs[lg]}: ${pk.done} / ${pk.total}');
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
  } catch (_) {}
  pk.running = false;
  if (--_active == 0) await svc('stop');
  pk.ping();
}

Future<Map?> fetchStore(String lg, String w) async {
  try {
    final r = await http.get(Uri.parse('$api/$lg/${Uri.encodeComponent(w)}')).timeout(const Duration(seconds: 25));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode == 200 && j is Map && j['word'] != null) {
      await db.insert('words', {'key': '$lg:$w', 'word': w, 'lang': lg, 'json': enc(j), 'ts': 0, 'fav': 0, 'seen': 0},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      addVocab(w);
      return j;
    }
  } catch (_) {}
  return null;
}

String sizeText(num b) =>
    b >= 1073741824 ? '${(b / 1073741824).toStringAsFixed(2)} GB' : '${(b / 1048576).toStringAsFixed(1)} MB';

String timeText(double sec) {
  final m = (sec / 60).round();
  if (m < 1) return 'أقل من دقيقة';
  if (m < 90) return '$m دقيقة';
  return '${(m / 60).toStringAsFixed(1)} ساعة';
}

/// Samples ~30 words, estimates the compressed size + time, asks for confirmation, then downloads.
Future<void> askAndRun(BuildContext context, String lg, int n, bool audio) async {
  if (packs[lg]!.running) return;
  final nav = Navigator.of(context, rootNavigator: true);
  final msg = ScaffoldMessenger.of(context);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
        content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Expanded(child: Text('بنحسب الحجم...'))])),
  );
  final words = (await wordList(refresh: true)).take(n).toList();
  final have = (await db.query('words', columns: ['word'], where: 'lang=?', whereArgs: [lg])).map((x) => x['word'] as String).toSet();
  final cut = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
  final miss = (await db.query('missing', columns: ['key'], where: 'ts>?', whereArgs: [cut])).map((x) => x['key'] as String).toSet();
  final todo = words.where((w) => !have.contains(w) && !miss.contains('$lg:$w')).toList();
  if (todo.isEmpty) {
    nav.pop();
    msg.showSnackBar(const SnackBar(content: Text('الكلمات دي كلها محمّلة')));
    return;
  }
  final k = todo.length < 30 ? todo.length : 30;
  final sample = [for (var i = 0; i < k; i++) todo[i * todo.length ~/ k]];
  final t0 = DateTime.now();
  var bytes = 0, found = 0, idx = 0;
  final urls = <String>[];
  Future<void> worker() async {
    while (idx < sample.length) {
      final j = await fetchStore(lg, sample[idx++]);
      if (j == null) continue;
      found++;
      bytes += enc(j).length;
      for (final x in (j['pronunciation'] as List? ?? [])) {
        if (x is Map && x['url'] is String) urls.add(x['url']);
      }
    }
  }

  await Future.wait([worker(), worker(), worker()]);
  final secPerWord = DateTime.now().difference(t0).inMilliseconds / 1000 / k;
  if (found == 0) {
    nav.pop();
    msg.showSnackBar(const SnackBar(content: Text('مش قادر أوصل للسيرفر، اتأكد من النت وجرّب تاني')));
    return;
  }
  final rate = found / k;
  final est = bytes / found * rate * todo.length;
  var audioLine = '';
  if (audio && urls.isNotEmpty) {
    var tot = 0, cnt = 0;
    for (final u in urls.take(6)) {
      try {
        final r = await http.head(Uri.parse(u), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 10));
        final l = int.tryParse(r.headers['content-length'] ?? '');
        if (l != null) {
          tot += l;
          cnt++;
        }
      } catch (_) {}
    }
    audioLine = cnt > 0
        ? '\nالصوت: ~${sizeText(tot / cnt * (urls.length / found) * rate * todo.length)} (مش بيتضغط)'
        : '\nالصوت: حجمه مش متاح قبل التحميل';
  }
  nav.pop();
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('تأكيد التحميل'),
      content: Text('${langs[lg]}\n${todo.length} كلمة جديدة\n\nالحجم على الموبايل (مضغوط): ~${sizeText(est)}$audioLine'
          '\nالوقت التقريبي: ~${timeText(secPerWord * todo.length)}\n\nالأرقام تقدير من عيّنة $k كلمة.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('حمّل')),
      ],
    ),
  );
  if (ok == true) runPack(lg, n, audio);
}

Future<void> deletePack(String lg) async {
  packs[lg]!.stop = true;
  await db.delete('words', where: 'lang=? AND seen=0 AND fav=0', whereArgs: [lg]);
  await db.delete('packs', where: 'lang=?', whereArgs: [lg]);
  await db.delete('missing', where: 'key LIKE ?', whereArgs: ['$lg:%']);
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
                child: Text('التحميل بيكمّل والأب في الخلفية (بإشعار فوق). لو قفلته من الريسنت بيقف ويكمّل لوحده لما تفتحه. "الكل" ممكن ياخد ساعات ومساحة كبيرة، فحمّل على قد احتياجك.'),
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
          if (pk.err.isNotEmpty) Text(pk.err, style: const TextStyle(color: orange)),
          if (pk.running) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pk.total == 0 ? null : pk.done / pk.total),
            Text('${pk.done} / ${pk.total}'),
            TextButton(onPressed: () => pk.stop = true, child: const Text('إيقاف مؤقت')),
          ] else
            Wrap(spacing: 8, children: [
              for (final n in [1000, 5000, 20000, 50000, 1000000])
                OutlinedButton(onPressed: () => askAndRun(context, lg, n, audio), child: Text(n >= 1000000 ? 'الكل (177 ألف)' : '$n')),
            ]),
        ]),
      ),
    );
  }
}
