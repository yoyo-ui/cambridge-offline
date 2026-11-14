import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'extras.dart';
import 'search.dart';

const api = 'https://dictionary-api.eliaschen.dev/api/dictionary';
const langs = {
  'en': 'English (US)',
  'uk': 'English (UK)',
  'en-cn': 'English → 中文 (简)',
  'en-tw': 'English → 中文 (繁)',
};
late Database db;
late Directory audioDir;
final player = AudioPlayer();
final lang = ValueNotifier<String>('en');
String s(Object? o) => o?.toString() ?? '';
Uint8List enc(Object j) => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(j))));
Map<String, dynamic> dec(Object v) =>
    Map<String, dynamic>.from(jsonDecode(v is String ? v : utf8.decode(gzip.decode(v as List<int>))));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  audioDir = Directory(p.join(dir.path, 'audio'))..createSync(recursive: true);
  db = await openDatabase(p.join(dir.path, 'dict.db'), version: 3,
      onCreate: (d, _) async {
        await d.execute(
            'CREATE TABLE words(key TEXT PRIMARY KEY, word TEXT, lang TEXT, json TEXT, ts INTEGER, fav INTEGER DEFAULT 0, seen INTEGER DEFAULT 1)');
        await d.execute(packsSql);
        await d.execute(missingSql);
      },
      onUpgrade: (d, o, _) async {
        if (o < 2) {
          await d.execute('ALTER TABLE words ADD COLUMN seen INTEGER DEFAULT 1');
          await d.execute(packsSql);
        }
        if (o < 3) await d.execute(missingSql);
      });
  runApp(const App());
  startServices();
}

class Entry {
  final Map<String, dynamic> data;
  final String key;
  bool fav;
  Entry(this.data, this.key, this.fav);
}

Future<Entry?> lookup(String lg, String q) async {
  final w = q.trim().toLowerCase();
  if (w.isEmpty) return null;
  final key = '$lg:$w';
  final now = DateTime.now().millisecondsSinceEpoch;
  final rows = await db.query('words', where: 'key=?', whereArgs: [key]);
  if (rows.isNotEmpty) {
    await db.update('words', {'ts': now, 'seen': 1}, where: 'key=?', whereArgs: [key]);
    return Entry(dec(rows.first['json'] as Object), key, rows.first['fav'] == 1);
  }
  try {
    final r = await http.get(Uri.parse('$api/$lg/${Uri.encodeComponent(w.replaceAll(' ', '-'))}')).timeout(const Duration(seconds: 15));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode == 200 && j is Map && j['word'] != null) {
      await db.insert('words', {'key': key, 'word': w, 'lang': lg, 'json': enc(j), 'ts': now, 'fav': 0, 'seen': 1});
      addVocab(w);
      saveAudio(j);
      return Entry(Map<String, dynamic>.from(j), key, false);
    }
  } catch (_) {}
  return null;
}

Future<File?> fetchAudio(String u) async {
  final clean = u.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
  final f = File(p.join(audioDir.path, clean.substring(clean.length > 100 ? clean.length - 100 : 0)));
  if (f.existsSync()) return f;
  try {
    final r = await http.get(Uri.parse(u), headers: {'User-Agent': 'Mozilla/5.0'});
    if (r.statusCode == 200) {
      await f.writeAsBytes(r.bodyBytes);
      return f;
    }
  } catch (_) {}
  return null;
}

Future<void> saveAudio(Map j) async {
  for (final x in (j['pronunciation'] as List? ?? [])) {
    if (x is Map && x['url'] is String) await fetchAudio(x['url']);
  }
}

Future<void> say(String u) async {
  final f = await fetchAudio(u);
  if (f != null) await player.play(DeviceFileSource(f.path));
}

Future<List<String>> suggest(String q) async => (await db.query('words',
        distinct: true, columns: ['word'], where: 'word LIKE ?', whereArgs: ['${q.toLowerCase()}%'], orderBy: 'word', limit: 8))
    .map((e) => e['word'] as String)
    .toList();

const navy = Color(0xFF0B2A5B);
const orange = Color(0xFFF26B1D);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
        seedColor: navy, brightness: b, primary: dark ? const Color(0xFF9DB8F5) : navy, secondary: orange),
    scaffoldBackgroundColor: dark ? const Color(0xFF0E1420) : const Color(0xFFF2F4F8),
    appBarTheme: AppBarTheme(backgroundColor: dark ? const Color(0xFF16203A) : navy, foregroundColor: Colors.white),
  );
}

BoxDecoration boxDec(ColorScheme cs) => BoxDecoration(
    color: cs.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.outlineVariant));

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navKey,
        title: 'Cambridge Offline',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  @override
  Widget build(BuildContext context) {
    const titles = ['', 'السجل', 'المفضلة', 'التحميلات'];
    final pages = [const SearchPage(), const ListPage(false), const ListPage(true), const DownloadsPage()];
    return Scaffold(
      appBar: i == 0 ? null : AppBar(title: Text(titles[i])),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'بحث'),
          NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
          NavigationDestination(icon: Icon(Icons.star), label: 'المفضلة'),
          NavigationDestination(icon: Icon(Icons.download), label: 'التحميلات'),
        ],
      ),
    );
  }
}

Future<void> open(BuildContext c, String w, String lg) =>
    Navigator.push<void>(c, MaterialPageRoute(builder: (_) => EntryPage(w, lg)));

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchState();
}

class _SearchState extends State<SearchPage> {
  final c = TextEditingController();
  List<String> sug = [], recent = [];
  String? wod;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await db.query('words', columns: ['word'], distinct: true, where: 'seen=1', orderBy: 'ts DESC', limit: 10);
    final w = await wordOfDay();
    if (mounted) {
      setState(() {
        recent = r.map((e) => e['word'] as String).toList();
        wod = w;
      });
    }
  }

  Future<void> onType(String v) async {
    final r = await smartSuggest(v, self: true);
    if (mounted) setState(() => sug = r);
  }

  void go(String w) {
    final x = w.trim();
    if (x.isEmpty) return;
    FocusScope.of(context).unfocus();
    open(context, x, lang.value).then((_) {
      if (mounted) load();
    });
  }

  Widget hl(String w, String q, TextTheme t) {
    final i = w.startsWith(q) ? q.length : 0;
    return Text.rich(TextSpan(style: t.bodyLarge, children: [
      TextSpan(text: w.substring(0, i)),
      TextSpan(text: w.substring(i), style: const TextStyle(fontWeight: FontWeight.w800)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final top = MediaQuery.of(context).padding.top;
    return AnnotatedRegion<SystemUiOverlayStyle>(value: SystemUiOverlayStyle.light, child: ListView(padding: EdgeInsets.zero, children: [
      Container(
        color: Theme.of(context).appBarTheme.backgroundColor,
        padding: EdgeInsets.fromLTRB(16, top + 20, 16, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cambridge Offline', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          const Text('قاموس بيشتغل من غير نت', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          ValueListenableBuilder<String>(
            valueListenable: lang,
            builder: (_, v, __) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final e in langs.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => lang.value = e.key,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: v == e.key ? orange : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: v == e.key ? orange : Colors.white54),
                        ),
                        child: Text(e.value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              filled: true,
              fillColor: cs.surface,
              hintText: 'Search for a word',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward, color: orange), onPressed: () => go(c.text)),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            ),
            onChanged: onType,
            onSubmitted: go,
          ),
        ]),
      ),
      if (sug.isNotEmpty)
        Container(
          color: cs.surface,
          child: Column(children: [
            for (final w in sug)
              ListTile(
                dense: true,
                leading: const Icon(Icons.search, size: 18),
                title: hl(w, c.text.trim().toLowerCase(), t),
                onTap: () => go(w),
              ),
          ]),
        )
      else
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (wod != null) ...[
              Text('كلمة اليوم', style: t.titleSmall),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => go(wod!),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: boxDec(cs),
                  child: Text(wod!, style: t.headlineSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (recent.isNotEmpty) ...[
              Text('آخر بحث', style: t.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final w in recent) ActionChip(label: Text(w), onPressed: () => go(w)),
              ]),
            ],
            if (recent.isEmpty && wod == null) const Text('اكتب كلمة وابدأ. أي كلمة بتدوّر عليها بتتحفظ وتشتغل بعدها من غير نت.'),
          ]),
        ),
    ]));
  }
}

class ListPage extends StatelessWidget {
  final bool fav;
  const ListPage(this.fav, {super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
        future: db.query('words', where: fav ? 'fav=1' : 'seen=1', orderBy: 'ts DESC'),
        builder: (c, snap) {
          final rows = snap.data ?? [];
          if (rows.isEmpty) {
            return Center(child: Text(fav ? 'مفيش كلمات في المفضلة لسه' : 'السجل فاضي، ابدأ دوّر على كلمة'));
          }
          return ListView(children: [
            for (final r in rows)
              ListTile(
                title: Text(r['word'] as String),
                subtitle: Text(langs[r['lang']] ?? ''),
                trailing: r['fav'] == 1 ? const Icon(Icons.star, color: Colors.amber) : null,
                onTap: () => open(c, r['word'] as String, r['lang'] as String),
              ),
          ]);
        },
      );
}

class EntryPage extends StatefulWidget {
  final String word, lg;
  const EntryPage(this.word, this.lg, {super.key});
  @override
  State<EntryPage> createState() => _EntryState();
}

class _EntryState extends State<EntryPage> {
  late final Future<Entry?> f = lookup(widget.lg, widget.word);

  @override
  Widget build(BuildContext context) => FutureBuilder<Entry?>(
        future: f,
        builder: (context, snap) {
          final e = snap.data;
          final done = snap.connectionState == ConnectionState.done;
          return Scaffold(
            appBar: AppBar(title: Text(langs[widget.lg] ?? '', style: const TextStyle(fontSize: 16)), actions: [
              if (e != null)
                IconButton(
                  icon: Icon(e.fav ? Icons.star : Icons.star_border, color: e.fav ? Colors.amber : null),
                  onPressed: () async {
                    e.fav = !e.fav;
                    await db.update('words', {'fav': e.fav ? 1 : 0}, where: 'key=?', whereArgs: [e.key]);
                    setState(() {});
                  },
                ),
            ]),
            body: !done
                ? const Center(child: CircularProgressIndicator())
                : e == null
                    ? NotFound(widget.word, widget.lg)
                    : content(context, e),
          );
        },
      );

  Widget content(BuildContext context, Entry e) {
    final d = e.data;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pos = (d['pos'] as List? ?? []).map(s).where((x) => x.isNotEmpty).toList();
    final pr = <String, Map>{};
    for (final x in (d['pronunciation'] as List? ?? [])) {
      if (x is Map && x['url'] is String) pr.putIfAbsent(s(x['lang']), () => x);
    }
    final verbs = (d['verbs'] as List? ?? []).whereType<Map>().toList();
    final groups = <String, List<Map>>{};
    for (final x in (d['definition'] as List? ?? []).whereType<Map>()) {
      groups.putIfAbsent(s(x['pos']), () => []).add(x);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: boxDec(cs),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(s(d['word']), style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: cs.primary)),
          if (pos.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(pos.join(', '),
                    style: const TextStyle(fontStyle: FontStyle.italic, color: orange, fontWeight: FontWeight.w600))),
          if (pr.isNotEmpty) const SizedBox(height: 12),
          Wrap(spacing: 20, runSpacing: 8, children: [
            for (final en in pr.entries)
              InkWell(
                onTap: () => say(s(en.value['url'])),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(en.key.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  const Icon(Icons.volume_up, color: orange),
                  const SizedBox(width: 6),
                  Text(s(en.value['pron'])),
                ]),
              ),
          ]),
        ]),
      ),
      if (verbs.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 12),
          decoration: boxDec(cs),
          child: ExpansionTile(
            title: const Text('Verb forms'),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final v in verbs) Chip(label: Text('${s(v['type'])}: ${s(v['text'])}')),
                ]),
              ),
            ],
          ),
        ),
      for (final g in groups.entries)
        Container(
          margin: const EdgeInsets.only(top: 14),
          decoration: boxDec(cs),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest, borderRadius: const BorderRadius.vertical(top: Radius.circular(11))),
              child: Text(g.key.isEmpty ? 'Definitions' : g.key,
                  style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w700, color: cs.primary, fontSize: 16)),
            ),
            for (var k = 0; k < g.value.length; k++) ...[
              if (k > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(s(g.value[k]['text']), style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  if (s(g.value[k]['translation']).isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(s(g.value[k]['translation']), style: t.bodyMedium?.copyWith(color: cs.primary))),
                  for (final ex in (g.value[k]['example'] as List? ?? []).whereType<Map>())
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.only(left: 12),
                      decoration: const BoxDecoration(border: Border(left: BorderSide(color: orange, width: 3))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s(ex['text'])),
                        if (s(ex['translation']).isNotEmpty)
                          Text(s(ex['translation']), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ]),
                    ),
                ]),
              ),
            ],
          ]),
        ),
    ]);
  }
}

class NotFound extends StatefulWidget {
  final String word, lg;
  const NotFound(this.word, this.lg, {super.key});
  @override
  State<NotFound> createState() => _NfState();
}

class _NfState extends State<NotFound> {
  late final Future<List<Object>> f = Future.wait<Object>([smartSuggest(widget.word), offline()]);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FutureBuilder<List<Object>>(
      future: f,
      builder: (c, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final sg = snap.data![0] as List<String>;
        final off = snap.data![1] as bool;
        return ListView(padding: const EdgeInsets.all(20), children: [
          const Icon(Icons.search_off, size: 56),
          const SizedBox(height: 12),
          Text('مفيش نتايج لـ "${widget.word}"', textAlign: TextAlign.center, style: t.titleLarge),
          if (off)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('مفيش نت دلوقتي والكلمة دي مش محفوظة عندك.', textAlign: TextAlign.center)),
          const SizedBox(height: 20),
          if (sg.isNotEmpty) ...[
            Text('ممكن تقصد:', style: t.titleMedium),
            for (final w in sg)
              ListTile(
                leading: const Icon(Icons.search),
                title: Text(w, style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.pushReplacement(c, MaterialPageRoute(builder: (_) => EntryPage(w, widget.lg))),
              ),
          ] else
            const Text('راجع الإملاء وجرّب تاني.', textAlign: TextAlign.center),
        ]);
      },
    );
  }
}
