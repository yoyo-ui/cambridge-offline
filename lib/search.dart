import 'main.dart';
import 'extras.dart';

List<String> vocab = [];

Future<void> loadVocab() async {
  final w = await wordList();
  final seen = <String>{...w};
  final c = await db.query('words', columns: ['word'], distinct: true);
  vocab = [...w, ...c.map((e) => e['word'] as String).where((x) => !seen.contains(x))];
}

void addVocab(String w) {
  if (!vocab.contains(w)) vocab.add(w);
}

int dist(String a, String b) {
  final m = a.length, n = b.length;
  final d = List.generate(m + 1, (i) => List<int>.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final c = a[i - 1] == b[j - 1] ? 0 : 1;
      var v = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && d[i - 2][j - 2] + 1 < v) {
        v = d[i - 2][j - 2] + 1;
      }
      d[i][j] = v;
    }
  }
  return d[m][n];
}

/// Prefix matches first (autocomplete), then close spellings ("did you mean").
Future<List<String>> smartSuggest(String q, {int limit = 8, bool self = false}) async {
  final w = q.trim().toLowerCase();
  if (w.isEmpty) return [];
  if (vocab.isEmpty) await loadVocab();
  final out = <String>[];
  if (self && vocab.contains(w)) out.add(w);
  for (final x in vocab) {
    if (out.length >= limit) break;
    if (x != w && x.startsWith(w)) out.add(x);
  }
  if (out.length < limit && w.length >= 3) {
    final max = w.length <= 3 ? 1 : 2;
    final keys = <int>[];
    for (var i = 0; i < vocab.length; i++) {
      final x = vocab[i];
      if (x == w || (x.length - w.length).abs() > max) continue;
      final dd = dist(w, x);
      if (dd <= max) keys.add(dd * 1000000 + i);
    }
    keys.sort();
    for (final k in keys) {
      if (out.length >= limit) break;
      final x = vocab[k % 1000000];
      if (!out.contains(x)) out.add(x);
    }
  }
  return out;
}

Future<String?> wordOfDay() async {
  if (vocab.isEmpty) await loadVocab();
  if (vocab.isEmpty) return null;
  final n = vocab.length < 3000 ? vocab.length : 3000;
  return vocab[DateTime.now().difference(DateTime(2024)).inDays % n];
}
