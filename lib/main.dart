import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  audioDir = Directory(p.join(dir.path, 'audio'))..createSync(recursive: true);
  db = await openDatabase(p.join(dir.path, 'dict.db'), version: 1,
      onCreate: (d, _) => d.execute(
          'CREATE TABLE words(key TEXT PRIMARY KEY, word TEXT, lang TEXT, json TEXT, ts INTEGER, fav INTEGER DEFAULT 0)'));
  runApp(const App());
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
    await db.update('words', {'ts': now}, where: 'key=?', whereArgs: [key]);
    return Entry(Map<String, dynamic>.from(jsonDecode(rows.first['json'] as String)), key, rows.first['fav'] == 1);
  }
  try {
    final r = await http.get(Uri.parse('$api/$lg/${Uri.encodeComponent(w)}')).timeout(const Duration(seconds: 15));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode == 200 && j is Map && j['word'] != null) {
      await db.insert('words', {'key': key, 'word': w, 'lang': lg, 'json': jsonEncode(j), 'ts': now, 'fav': 0});
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

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cambridge Offline',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0B6E6E)),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF0B6E6E)),
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
    const titles = ['', 'السجل', 'المفضلة'];
    final pages = [const SearchPage(), const ListPage(false), const ListPage(true)];
    return Scaffold(
      appBar: i == 0 ? null : AppBar(title: Text(titles[i])),
      body: SafeArea(child: pages[i]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'بحث'),
          NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
          NavigationDestination(icon: Icon(Icons.star), label: 'المفضلة'),
        ],
      ),
    );
  }
}

void open(BuildContext c, String w, String lg) =>
    Navigator.push(c, MaterialPageRoute(builder: (_) => EntryPage(w, lg)));

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchState();
}

class _SearchState extends State<SearchPage> {
  final c = TextEditingController();
  List<String> sug = [];
  void go(String w) {
    if (w.trim().isNotEmpty) open(context, w.trim(), lang.value);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 12),
        Text('قاموس كامبريدج', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('أي كلمة تدور عليها بتتحفظ وتشتغل من غير نت', style: t.bodyMedium),
        const SizedBox(height: 14),
        ValueListenableBuilder<String>(
          valueListenable: lang,
          builder: (_, v, __) => Wrap(spacing: 8, children: [
            for (final e in langs.entries)
              ChoiceChip(label: Text(e.value), selected: v == e.key, onSelected: (_) => lang.value = e.key),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: c,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'اكتب كلمة إنجليزي...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => go(c.text)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
          ),
          onChanged: (v) async {
            final r = v.isEmpty ? <String>[] : await suggest(v);
            if (mounted) setState(() => sug = r);
          },
          onSubmitted: go,
        ),
        Expanded(
          child: ListView(children: [
            for (final w in sug)
              ListTile(leading: const Icon(Icons.offline_pin), title: Text(w), onTap: () => go(w)),
          ]),
        ),
      ]),
    );
  }
}

class ListPage extends StatelessWidget {
  final bool fav;
  const ListPage(this.fav, {super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
        future: db.query('words', where: fav ? 'fav=1' : null, orderBy: 'ts DESC'),
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
            appBar: AppBar(title: Text(widget.word), actions: [
              if (e != null)
                IconButton(
                  icon: Icon(e.fav ? Icons.star : Icons.star_border),
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
                    ? const Center(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('مش لاقي الكلمة دي. اتأكد من الإملاء، والكلمة الجديدة محتاجة نت أول مرة بس.',
                                textAlign: TextAlign.center)))
                    : content(context, e),
          );
        },
      );

  Widget content(BuildContext context, Entry e) {
    final d = e.data;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final pos = (d['pos'] as List? ?? []).map(s).toList();
    final prons = <String, Map>{};
    for (final x in (d['pronunciation'] as List? ?? [])) {
      if (x is Map && x['url'] is String) prons['${x['lang']}${x['url']}'] = x;
    }
    final verbs = (d['verbs'] as List? ?? []).whereType<Map>().toList();
    final groups = <String, List<Map>>{};
    for (final x in (d['definition'] as List? ?? []).whereType<Map>()) {
      groups.putIfAbsent(s(x['pos']), () => []).add(x);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(s(d['word']), style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [for (final x in pos) Chip(label: Text(x))]),
      for (final x in prons.values)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text('${s(x['lang']).toUpperCase()}   ${s(x['pron'])}'),
          trailing: IconButton(icon: const Icon(Icons.volume_up), onPressed: () => say(s(x['url']))),
        ),
      if (verbs.isNotEmpty)
        ExpansionTile(
          title: const Text('تصريفات الفعل'),
          children: [
            Wrap(spacing: 8, children: [for (final v in verbs) Chip(label: Text('${s(v['type'])}: ${s(v['text'])}'))])
          ],
        ),
      for (final g in groups.entries) ...[
        if (g.key.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(g.key, style: t.titleLarge?.copyWith(color: cs.primary))),
        for (final x in g.value)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(s(x['text']), style: t.bodyLarge),
                if (s(x['translation']).isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(s(x['translation']), style: t.bodyMedium?.copyWith(color: cs.primary))),
                for (final ex in (x['example'] as List? ?? []).whereType<Map>())
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                        '• ${s(ex['text'])}${s(ex['translation']).isEmpty ? '' : '\n   ${s(ex['translation'])}'}',
                        style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                  ),
              ]),
            ),
          ),
      ],
    ]);
  }
}
