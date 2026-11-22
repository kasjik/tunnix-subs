// Finds free proxy subscription links on GitHub, tests them, scores their
// stability across runs and publishes the best to subscriptions.json, which
// the Tunnix app downloads.
//
// Run weekly by .github/workflows/update.yml. Locally:
//   dart pub get && dart run bin/find_subs.dart
// (set GITHUB_TOKEN for higher API limits; MAX_REPOS limits the search).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tunnix_subs/parsers.dart';
import 'package:tunnix_subs/proxy_node.dart';

/// How many links to publish, and at most how many from one repository.
const publishCount = 8;
const perRepoLimit = 2;

/// A link is dropped after failing this many runs in a row.
const dropAfterFails = 3;

/// Runs kept per link for scoring.
const historyLength = 6;

/// Repositories never to use ("owner/name"), e.g. ones serving bad nodes.
const blockedRepos = <String>{};

/// Search phrases for repositories that publish free node lists.
const searchQueries = [
  'v2ray free subscription',
  'free v2ray nodes',
  'clash free nodes',
  'free vmess vless trojan',
  'v2rayN subscription',
  'free proxy subscription shadowsocks',
];

/// File paths that usually hold a subscription.
final _candidatePath = RegExp(
  r'(^|/)[^/]*(sub|v2ray|clash|node|mix|all|base64|vmess|vless|trojan|'
  r'shadowsocks|ss|proxies|config)[^/]*(\.txt|\.ya?ml|\.json)?$',
  caseSensitive: false,
);
final _skipPath = RegExp(
  r'(^|/)(\.github|docs?|test|tests|example|examples|node_modules|src)/|'
  r'(^|/)\.[^/]*$|' // dotfiles (.editorconfig, .pre-commit-config.yaml)
  r'readme|license|package(-lock)?\.json|ledger|'
  r'\.(md|html|css|jsx?|tsx?|py|go|rs|sh|bat|png|jpe?g|gif|svg)$',
  caseSensitive: false,
);

final _token = Platform.environment['GITHUB_TOKEN'];
final _maxRepos = int.tryParse(Platform.environment['MAX_REPOS'] ?? '') ?? 30;
final _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'tunnix-subs-finder';

Future<void> main() async {
  final now = DateTime.now().toUtc();
  final state = _readJson('state.json') ?? {};
  final links = Map<String, Map<String, dynamic>>.from(
    (state['links'] as Map?)?.map(
          (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
        ) ??
        {},
  );
  final seeds = [
    for (final e in (_readJson('seeds.json')?['seeds'] as List? ?? const []))
      if (e is Map && e['url'] is String) e['url'] as String,
  ];

  // 1. Candidates: seeds + links already tracked + fresh finds.
  final candidates = <String, String>{}; // url -> repo ("" for seeds)
  for (final u in seeds) {
    candidates[u] = _repoOf(u) ?? '';
  }
  for (final e in links.entries) {
    candidates[e.key] = (e.value['repo'] as String?) ?? '';
  }
  final found = await _discover(now);
  for (final e in found.entries) {
    candidates.putIfAbsent(e.key, () => e.value);
  }
  stdout.writeln(
    'Candidates: ${candidates.length} '
    '(${seeds.length} seeds, ${links.length} tracked, ${found.length} found)',
  );

  // 2. Test every candidate.
  final results = await _pool(
    candidates.keys.toList(),
    6,
    (url) async => MapEntry(url, await _evaluate(url)),
  );

  // 3. Record history.
  for (final r in results) {
    final url = r.key;
    final run = r.value;
    final entry = links.putIfAbsent(
      url,
      () => {
        'repo': candidates[url],
        'firstSeen': now.toIso8601String(),
        'runs': <dynamic>[],
        'failStreak': 0,
      },
    );
    final runs = List<dynamic>.from(entry['runs'] as List)
      ..add({'date': now.toIso8601String(), ...run.toJson()});
    entry['runs'] = runs.length > historyLength
        ? runs.sublist(runs.length - historyLength)
        : runs;
    entry['failStreak'] = run.ok ? 0 : ((entry['failStreak'] as int?) ?? 0) + 1;
  }

  // Forget links that keep failing (seeds are always retried) and blocked ones.
  links.removeWhere(
    (url, e) =>
        blockedRepos.contains(e['repo']) ||
        (!seeds.contains(url) &&
            ((e['failStreak'] as int?) ?? 0) >= dropAfterFails),
  );

  // 4. Score and pick.
  final scored =
      [
          for (final e in links.entries)
            if (((e.value['failStreak'] as int?) ?? 0) == 0)
              (
                url: e.key,
                repo: e.value['repo'] as String? ?? '',
                score: _score(e.value),
              ),
        ]
        ..removeWhere((s) => s.score <= 0)
        ..sort((a, b) => b.score.compareTo(a.score));
  final picked = <({String url, String repo, double score})>[];
  final perRepo = <String, int>{};
  // Seeds that work this run always go first: a known safety net even if
  // GitHub search turns up nothing good.
  for (final s in scored.where((s) => seeds.contains(s.url)).toList()) {
    picked.add(s);
    scored.remove(s);
  }
  for (final s in scored) {
    if (picked.length >= publishCount) break;
    final key = s.repo.isEmpty ? s.url : s.repo;
    if ((perRepo[key] ?? 0) >= perRepoLimit) continue;
    perRepo[key] = (perRepo[key] ?? 0) + 1;
    picked.add(s);
  }

  // 5. Publish — but never replace a working list with an empty one
  // (e.g. if GitHub or the network had a bad day).
  if (picked.isEmpty) {
    stderr.writeln('No working links this run; keeping subscriptions.json.');
  } else {
    _writeJson('subscriptions.json', {
      'updated': now.toIso8601String(),
      'subscriptions': [
        for (final p in picked) {'name': _nameFor(p.url, p.repo), 'url': p.url},
      ],
    });
    stdout.writeln('Published ${picked.length}:');
    for (final p in picked) {
      stdout.writeln('  ${p.score.toStringAsFixed(1).padLeft(6)}  ${p.url}');
    }
  }

  // State always changes (lastRun), so every run commits — which also keeps
  // GitHub from disabling the schedule after 60 days without activity.
  _writeJson('state.json', {'lastRun': now.toIso8601String(), 'links': links});
  _http.close(force: true);
}

// ------------------------------------------------------------------ discovery

Future<Map<String, String>> _discover(DateTime now) async {
  final since = now.subtract(const Duration(days: 14));
  final day = since.toIso8601String().substring(0, 10);
  final repos = <String, ({String branch, int stars})>{};
  for (final q in searchQueries) {
    final j = await _api('/search/repositories', {
      'q': '$q pushed:>$day',
      'sort': 'updated',
      'per_page': '30',
    });
    for (final r in (j?['items'] as List? ?? const [])) {
      if (r is! Map || r['fork'] == true || r['archived'] == true) continue;
      if (blockedRepos.contains(r['full_name'])) continue;
      repos[r['full_name'] as String] = (
        branch: r['default_branch'] as String? ?? 'main',
        stars: (r['stargazers_count'] as num?)?.toInt() ?? 0,
      );
    }
  }
  final top = repos.entries.toList()
    ..sort((a, b) => b.value.stars.compareTo(a.value.stars));
  final out = <String, String>{};
  for (final r in top.take(_maxRepos)) {
    final tree = await _api('/repos/${r.key}/git/trees/${r.value.branch}', {
      'recursive': '1',
    });
    final files =
        [
            for (final t in (tree?['tree'] as List? ?? const []))
              if (t is Map &&
                  t['type'] == 'blob' &&
                  ((t['size'] as num?) ?? 0) > 200 &&
                  ((t['size'] as num?) ?? 0) < 5e6)
                t['path'] as String,
          ]
          ..retainWhere(
            (p) =>
                '/'.allMatches(p).length <= 2 &&
                _candidatePath.hasMatch(p) &&
                !_skipPath.hasMatch(p),
          )
          ..sort((a, b) => a.length.compareTo(b.length));
    for (final p in files.take(6)) {
      final path = p.split('/').map(Uri.encodeComponent).join('/');
      out['https://raw.githubusercontent.com/${r.key}/${r.value.branch}/$path'] =
          r.key;
    }
  }
  return out;
}

Future<Map<String, dynamic>?> _api(String path, Map<String, String> q) async {
  try {
    final req = await _http.getUrl(Uri.https('api.github.com', path, q));
    req.headers.set('Accept', 'application/vnd.github+json');
    final token = _token;
    if (token != null && token.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $token');
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      stderr.writeln('GitHub $path → ${res.statusCode}');
      return null;
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('GitHub $path failed: $e');
    return null;
  }
}

// ----------------------------------------------------------------- evaluation

class _Run {
  _Run(this.nodes, this.working, [this.error]);
  final int nodes;
  final int working;
  final String? error;

  /// Enough live servers to be worth publishing.
  bool get ok => working >= 3;

  Map<String, Object?> toJson() => {
    'nodes': nodes,
    'working': working,
    'error': ?error,
  };
}

Future<_Run> _evaluate(String url) async {
  String body;
  try {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) return _Run(0, 0, 'HTTP ${res.statusCode}');
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 25))) {
      bytes.addAll(chunk);
      if (bytes.length > 5e6) return _Run(0, 0, 'too large');
    }
    body = utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    return _Run(0, 0, 'fetch failed');
  }
  List<ProxyNode> nodes;
  try {
    nodes = parseSubscription(body, 'x');
  } catch (_) {
    return _Run(0, 0, 'unparseable');
  }
  if (nodes.isEmpty) return _Run(0, 0, 'no nodes');

  // Test a random sample: TCP connect proves the server is up.
  final sample = (List.of(nodes)..shuffle(Random(url.hashCode))).take(40);
  final up = await _pool(sample.toList(), 20, _tcpOk);
  final ratio = up.where((x) => x).length / up.length;
  return _Run(nodes.length, (ratio * nodes.length).round());
}

Future<bool> _tcpOk(ProxyNode n) async {
  try {
    final s = await Socket.connect(
      n.server,
      n.port,
      timeout: const Duration(seconds: 4),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Average working servers (capped, so one huge dump doesn't dominate),
/// weighted by how reliably the link worked across its recent runs.
/// Links seen only once score lower than proven ones.
double _score(Map<String, dynamic> e) {
  final runs = [
    for (final r in (e['runs'] as List)) Map<String, dynamic>.from(r as Map),
  ];
  if (runs.isEmpty) return 0;
  final working = [for (final r in runs) min((r['working'] as int?) ?? 0, 150)];
  final okRuns = working.where((w) => w >= 3).length;
  final avg = working.reduce((a, b) => a + b) / working.length;
  final reliability = okRuns / runs.length;
  final maturity = 0.6 + 0.4 * min(runs.length, 4) / 4;
  return avg * reliability * maturity;
}

// ---------------------------------------------------------------------- utils

Future<List<R>> _pool<T, R>(
  List<T> items,
  int concurrency,
  Future<R> Function(T) f,
) async {
  final out = List<R?>.filled(items.length, null);
  var i = 0;
  Future<void> worker() async {
    while (i < items.length) {
      final k = i++;
      out[k] = await f(items[k]);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  return out.cast<R>();
}

String? _repoOf(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host != 'raw.githubusercontent.com') return null;
  final s = u.pathSegments;
  return s.length >= 2 ? '${s[0]}/${s[1]}' : null;
}

String _nameFor(String url, String repo) {
  final file = Uri.parse(url).pathSegments.lastOrNull ?? '';
  if (repo.isEmpty) return Uri.parse(url).host;
  return '${repo.split('/').last} · $file';
}

Map<String, dynamic>? _readJson(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

void _writeJson(String path, Object value) => File(
  path,
).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(value)}\n');
