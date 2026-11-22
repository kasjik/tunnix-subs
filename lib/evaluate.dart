// Judges a subscription link the way the Tunnix app will experience it:
// distinct server IPs, minus CDN-fronted ones (the app can't locate those and
// skips them), and — the part that matters — whether a sample of servers
// actually carries traffic, tested with a real request through sing-box.
// An open TCP port alone says little: CDN edges and broken proxies accept
// connections too.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'parsers.dart';
import 'proxy_node.dart';

/// How many distinct, non-CDN servers per link get a real proxy test.
const testSample = 24;

/// Resolved per link (lists can hold thousands; a sample is enough).
const resolveSample = 250;

class Evaluation {
  Evaluation({
    this.nodes = 0,
    this.uniqueIps = 0,
    this.cdn = 0,
    this.tested = 0,
    this.working = 0,
    Set<String>? usableIps,
    this.error,
  }) : usableIps = usableIps ?? {};

  /// Servers in the file.
  final int nodes;

  /// Distinct IPs among the resolved sample.
  final int uniqueIps;

  /// Of those, behind a CDN (useless to the app).
  final int cdn;

  /// Real proxy tests run, and how many passed.
  final int tested;
  final int working;

  /// Distinct non-CDN IPs (to measure overlap between links).
  final Set<String> usableIps;

  final String? error;

  double get workingRatio => tested == 0 ? 0 : working / tested;

  /// Estimated servers the app could actually use from this link.
  int get usable => ((uniqueIps - cdn) * workingRatio).round();

  bool get ok => usable >= 3;

  Map<String, Object?> toJson() => {
    'nodes': nodes,
    'unique': uniqueIps,
    'cdn': cdn,
    'tested': tested,
    'working': working,
    'usable': usable,
    'error': ?error,
  };
}

Future<Evaluation> evaluate(
  String url,
  HttpClient http,
  CdnRanges cdnRanges,
  ProxyTester tester,
) async {
  String body;
  try {
    final req = await http.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return Evaluation(error: 'HTTP ${res.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 25))) {
      bytes.addAll(chunk);
      if (bytes.length > 5e6) return Evaluation(error: 'too large');
    }
    body = utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return Evaluation(error: 'fetch failed');
  }
  List<ProxyNode> nodes;
  try {
    nodes = parseSubscription(body, 'x');
  } catch (_) {
    return Evaluation(error: 'unparseable');
  }
  if (nodes.isEmpty) return Evaluation(error: 'no nodes');

  // Distinct IPs, like the app's duplicate check.
  final sample = (List.of(
    nodes,
  )..shuffle(Random(url.hashCode))).take(resolveSample).toList();
  final ips = await mapPool(sample, 32, (n) => resolveIp(n.server));
  final byIp = <String, ProxyNode>{};
  for (var k = 0; k < sample.length; k++) {
    final ip = ips[k];
    if (ip != null) byIp.putIfAbsent(ip, () => sample[k]);
  }
  final usable = {
    for (final e in byIp.entries)
      if (!cdnRanges.contains(e.key)) e.key: e.value,
  };

  // Real traffic through a sample of what's left.
  final toTest = usable.values.take(testSample).toList();
  final results = await tester.test(toTest);
  return Evaluation(
    nodes: nodes.length,
    uniqueIps: byIp.length,
    cdn: byIp.length - usable.length,
    tested: toTest.length,
    working: results.where((x) => x).length,
    usableIps: usable.keys.toSet(),
  );
}

// ------------------------------------------------------------- proxy tests

/// Tests proxies with sing-box: one process per batch, each server behind
/// its own local port, then a real HTTPS request through each port.
class ProxyTester {
  ProxyTester({this.binary = 'sing-box', this.basePort = 21000});

  final String binary;
  final int basePort;
  int _slot = 0;

  static final _testUrl = Uri.parse('https://www.gstatic.com/generate_204');

  Future<List<bool>> test(List<ProxyNode> nodes) async {
    if (nodes.isEmpty) return const [];
    // Separate port ranges so concurrent batches don't collide.
    final base = basePort + (_slot++ % 8) * 200;
    final dir = await Directory.systemTemp.createTemp('subs-test');
    try {
      // Drop servers sing-box can't load, so one bad entry doesn't sink the
      // whole batch.
      var batch = nodes;
      if (!await _check(dir, batch)) {
        final ok = await mapPool(batch, 8, (n) => _check(dir, [n]));
        batch = [
          for (var k = 0; k < batch.length; k++)
            if (ok[k]) batch[k],
        ];
      }
      final pass = <ProxyNode>{};
      if (batch.isNotEmpty) {
        final cfg = File('${dir.path}/run.json')
          ..writeAsStringSync(jsonEncode(_config(batch, base)));
        final proc = await Process.start(binary, ['run', '-c', cfg.path]);
        unawaited(proc.stdout.drain<void>());
        unawaited(proc.stderr.drain<void>());
        try {
          await _waitForPort(base, const Duration(seconds: 8));
          final ok = await mapPool(
            List.generate(batch.length, (k) => k),
            batch.length,
            (k) => _fetchVia(base + k),
          );
          for (var k = 0; k < batch.length; k++) {
            if (ok[k]) pass.add(batch[k]);
          }
        } finally {
          proc.kill();
          await proc.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              proc.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
      }
      return [for (final n in nodes) pass.contains(n)];
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<bool> _check(Directory dir, List<ProxyNode> nodes) async {
    final f = File(
      '${dir.path}/check-${nodes.length}-${nodes.first.id.hashCode}.json',
    )..writeAsStringSync(jsonEncode(_config(nodes, basePort)));
    final r = await Process.run(binary, ['check', '-c', f.path]);
    return r.exitCode == 0;
  }

  static Map<String, Object?> _config(List<ProxyNode> nodes, int base) => {
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': 'local'},
      ],
    },
    'inbounds': [
      for (var k = 0; k < nodes.length; k++)
        {
          'type': 'mixed',
          'tag': 'in$k',
          'listen': '127.0.0.1',
          'listen_port': base + k,
        },
    ],
    'outbounds': [
      for (var k = 0; k < nodes.length; k++)
        {...nodes[k].outbound, 'tag': 'o$k'},
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'rules': [
        for (var k = 0; k < nodes.length; k++)
          {
            'inbound': ['in$k'],
            'outbound': 'o$k',
          },
      ],
      'final': 'direct',
      'default_domain_resolver': 'local',
    },
  };

  static Future<void> _waitForPort(int port, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        s.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  static Future<bool> _fetchVia(int port) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(_testUrl)
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return res.statusCode == 204;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

// --------------------------------------------------------------- CDN ranges

/// Published IP ranges of CDNs that front free proxies (Cloudflare, Fastly).
class CdnRanges {
  final _v4 = <(int, int)>[]; // (network, mask)
  final _v6 = <(BigInt, BigInt)>[];

  static Future<CdnRanges> load(HttpClient http) async {
    final r = CdnRanges();
    Future<String> get(String url) async {
      try {
        final req = await http.getUrl(Uri.parse(url));
        final res = await req.close().timeout(const Duration(seconds: 15));
        return await res.transform(utf8.decoder).join();
      } catch (_) {
        return '';
      }
    }

    final cidrs = <String>[
      ...const LineSplitter().convert(
        await get('https://www.cloudflare.com/ips-v4'),
      ),
      ...const LineSplitter().convert(
        await get('https://www.cloudflare.com/ips-v6'),
      ),
    ];
    try {
      final j =
          jsonDecode(await get('https://api.fastly.com/public-ip-list'))
              as Map<String, dynamic>;
      cidrs
        ..addAll((j['addresses'] as List).cast<String>())
        ..addAll((j['ipv6_addresses'] as List).cast<String>());
    } catch (_) {}
    for (final c in cidrs) {
      r._add(c.trim());
    }
    return r;
  }

  void _add(String cidr) {
    final parts = cidr.split('/');
    if (parts.length != 2) return;
    final addr = InternetAddress.tryParse(parts[0]);
    final bits = int.tryParse(parts[1]);
    if (addr == null || bits == null) return;
    if (addr.type == InternetAddressType.IPv4) {
      final mask = bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
      _v4.add((_v4int(addr) & mask, mask));
    } else {
      final all = (BigInt.one << 128) - BigInt.one;
      final mask = bits == 0 ? BigInt.zero : (all << (128 - bits)) & all;
      _v6.add((_v6int(addr) & mask, mask));
    }
  }

  bool contains(String ip) {
    final a = InternetAddress.tryParse(ip);
    if (a == null) return false;
    if (a.type == InternetAddressType.IPv4) {
      final v = _v4int(a);
      return _v4.any((r) => v & r.$2 == r.$1);
    }
    final v = _v6int(a);
    return _v6.any((r) => v & r.$2 == r.$1);
  }

  int get size => _v4.length + _v6.length;

  static int _v4int(InternetAddress a) =>
      a.rawAddress.fold(0, (acc, b) => (acc << 8) | b);
  static BigInt _v6int(InternetAddress a) =>
      a.rawAddress.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
}

// ------------------------------------------------------------------ helpers

Future<String?> resolveIp(String host) async {
  if (InternetAddress.tryParse(host) != null) return host;
  try {
    final r = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 5));
    return r.isEmpty ? null : r.first.address;
  } catch (_) {
    return null;
  }
}

/// Runs [f] over [items], [concurrency] at a time; results keep order.
Future<List<R>> mapPool<T, R>(
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

  await Future.wait(List.generate(max(1, concurrency), (_) => worker()));
  return out.cast<R>();
}
