import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'proxy_node.dart';

/// Parses a subscription body: Clash/Mihomo YAML, or share links
/// (plain or base64-encoded). Unsupported entries are skipped.
List<ProxyNode> parseSubscription(String body, String subscriptionId) {
  final text = body.trim();
  if (text.isEmpty) return const [];

  final drafts = text.contains(RegExp(r'^proxies\s*:', multiLine: true))
      ? _parseClash(text)
      : _parseLinks(text.contains('://') ? text : _tryBase64(text) ?? text);

  final seen = <String>{};
  final nodes = <ProxyNode>[];
  for (final d in drafts) {
    // Identity = connection settings, not the display name: the same server
    // keeps its health history across renames, updates and subscriptions.
    final key = jsonEncode(d.outbound);
    if (!seen.add(key)) continue;
    nodes.add(
      ProxyNode(
        id: 'n:${_hash(key)}',
        name: d.name,
        protocol: d.protocol,
        server: d.server,
        port: d.port,
        subscriptionId: subscriptionId,
        outbound: d.outbound,
      ),
    );
  }
  return nodes;
}

class _Draft {
  _Draft(this.name, this.protocol, this.server, this.port, this.outbound);
  final String name;
  final String protocol;
  final String server;
  final int port;
  final Map<String, Object?> outbound;
}

// ---------------------------------------------------------------- Clash YAML

List<_Draft> _parseClash(String text) {
  final Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException {
    return const [];
  }
  if (doc is! Map || doc['proxies'] is! List) return const [];
  final out = <_Draft>[];
  for (final p in doc['proxies'] as List) {
    if (p is! Map) continue;
    try {
      final d = _clashProxy(p);
      if (d != null) out.add(d);
    } catch (_) {
      // Malformed entry: skip it, keep the rest.
    }
  }
  return out;
}

_Draft? _clashProxy(Map p) {
  final type = '${p['type']}'.toLowerCase();
  final server = p['server']?.toString();
  final port = _int(p['port']);
  final name = p['name']?.toString() ?? '$server:$port';
  if (server == null || port == null) return null;
  final insecure = p['skip-cert-verify'] == true;
  final sni = (p['sni'] ?? p['servername'])?.toString();
  final alpn = (p['alpn'] as List?)?.map((e) => '$e').toList();
  final fp = p['client-fingerprint']?.toString();

  Map<String, Object?>? transport() {
    final net = p['network']?.toString();
    final ws = p['ws-opts'] as Map?;
    final grpc = p['grpc-opts'] as Map?;
    final h2 = p['h2-opts'] as Map?;
    return _transport(
      net,
      path: (ws?['path'] ?? p['ws-path'] ?? (h2?['path']))?.toString(),
      host:
          ((ws?['headers'] as Map?)?['Host'] ??
                  (p['ws-headers'] as Map?)?['Host'] ??
                  (h2?['host'] is List
                      ? (h2!['host'] as List).firstOrNull
                      : null))
              ?.toString(),
      serviceName: grpc?['grpc-service-name']?.toString(),
    );
  }

  switch (type) {
    case 'ss':
      final plugin = p['plugin']?.toString();
      final ob = <String, Object?>{
        'type': 'shadowsocks',
        'server': server,
        'server_port': port,
        'method': '${p['cipher']}',
        'password': '${p['password']}',
      };
      if (plugin != null) {
        if (plugin != 'obfs') {
          return null; // v2ray-plugin, shadow-tls… unsupported
        }
        final o = (p['plugin-opts'] as Map?) ?? const {};
        ob['plugin'] = 'obfs-local';
        ob['plugin_opts'] =
            'obfs=${o['mode'] ?? 'http'}'
            '${o['host'] != null ? ';obfs-host=${o['host']}' : ''}';
      }
      return _Draft(name, 'shadowsocks', server, port, ob);

    case 'vmess':
      return _Draft(name, 'vmess', server, port, {
        'type': 'vmess',
        'server': server,
        'server_port': port,
        'uuid': '${p['uuid']}',
        'security': p['cipher']?.toString() ?? 'auto',
        'alter_id': _int(p['alterId']) ?? 0,
        if (p['tls'] == true)
          'tls': _tls(sni: sni, insecure: insecure, alpn: alpn, fp: fp),
        ...?_wrap('transport', transport()),
      });

    case 'trojan':
      return _Draft(name, 'trojan', server, port, {
        'type': 'trojan',
        'server': server,
        'server_port': port,
        'password': '${p['password']}',
        'tls': _tls(sni: sni, insecure: insecure, alpn: alpn, fp: fp),
        ...?_wrap('transport', transport()),
      });

    case 'vless':
      final reality = p['reality-opts'] as Map?;
      return _Draft(name, 'vless', server, port, {
        'type': 'vless',
        'server': server,
        'server_port': port,
        'uuid': '${p['uuid']}',
        if (p['flow'] != null && '${p['flow']}'.isNotEmpty)
          'flow': '${p['flow']}',
        'packet_encoding': 'xudp',
        if (p['tls'] == true || reality != null)
          'tls': _tls(
            sni: sni,
            insecure: insecure,
            alpn: alpn,
            fp: fp,
            realityKey: reality?['public-key']?.toString(),
            realityShortId: reality?['short-id']?.toString(),
          ),
        ...?_wrap('transport', transport()),
      });

    case 'hysteria2':
    case 'hy2':
      return _Draft(name, 'hysteria2', server, port, {
        'type': 'hysteria2',
        'server': server,
        'server_port': port,
        'password': '${p['password'] ?? p['auth'] ?? ''}',
        if (p['obfs'] != null)
          'obfs': {
            'type': '${p['obfs']}',
            'password': '${p['obfs-password'] ?? ''}',
          },
        'tls': _tls(sni: sni, insecure: insecure, alpn: alpn ?? const ['h3']),
      });
  }
  return null;
}

// --------------------------------------------------------------- share links

List<_Draft> _parseLinks(String text) {
  final out = <_Draft>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    try {
      final d = _link(line);
      if (d != null) out.add(d);
    } catch (_) {
      // Skip malformed links.
    }
  }
  return out;
}

_Draft? _link(String line) {
  final scheme = line.split('://').first.toLowerCase();
  if (scheme == 'vmess') return _vmessLink(line);
  if (scheme == 'ss') return _ssLink(line);

  final uri = Uri.parse(line);
  final q = uri.queryParameters;
  final name = uri.fragment.isEmpty
      ? '${uri.host}:${uri.port}'
      : Uri.decodeComponent(uri.fragment);
  final user = Uri.decodeComponent(uri.userInfo);
  final insecure = q['allowInsecure'] == '1' || q['insecure'] == '1';
  final sni = q['sni'] ?? q['peer'];
  final alpn = q['alpn']?.split(',');
  final transport = _transport(
    q['type'],
    path: q['path'],
    host: q['host'],
    serviceName: q['serviceName'],
  );

  switch (scheme) {
    case 'trojan':
      return _Draft(name, 'trojan', uri.host, uri.port, {
        'type': 'trojan',
        'server': uri.host,
        'server_port': uri.port,
        'password': user,
        'tls': _tls(sni: sni, insecure: insecure, alpn: alpn, fp: q['fp']),
        ...?_wrap('transport', transport),
      });
    case 'vless':
      final security = q['security'] ?? 'none';
      return _Draft(name, 'vless', uri.host, uri.port, {
        'type': 'vless',
        'server': uri.host,
        'server_port': uri.port,
        'uuid': user,
        if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
        'packet_encoding': 'xudp',
        if (security == 'tls' || security == 'reality')
          'tls': _tls(
            sni: sni,
            insecure: insecure,
            alpn: alpn,
            fp: q['fp'],
            realityKey: security == 'reality' ? q['pbk'] : null,
            realityShortId: q['sid'],
          ),
        ...?_wrap('transport', transport),
      });
    case 'hysteria2':
    case 'hy2':
      return _Draft(name, 'hysteria2', uri.host, uri.port, {
        'type': 'hysteria2',
        'server': uri.host,
        'server_port': uri.port,
        'password': user,
        if (q['obfs'] != null)
          'obfs': {'type': q['obfs'], 'password': q['obfs-password'] ?? ''},
        'tls': _tls(sni: sni, insecure: insecure, alpn: alpn ?? const ['h3']),
      });
  }
  return null;
}

_Draft? _vmessLink(String line) {
  final json = _tryBase64(line.substring('vmess://'.length));
  if (json == null) return null;
  final j = jsonDecode(json) as Map<String, Object?>;
  final server = '${j['add']}';
  final port = _int(j['port'])!;
  final tls = j['tls'] == 'tls';
  return _Draft('${j['ps'] ?? '$server:$port'}', 'vmess', server, port, {
    'type': 'vmess',
    'server': server,
    'server_port': port,
    'uuid': '${j['id']}',
    'security': (j['scy'] as String?)?.isNotEmpty == true ? j['scy'] : 'auto',
    'alter_id': _int(j['aid']) ?? 0,
    if (tls)
      'tls': _tls(
        sni: (j['sni'] as String?)?.isNotEmpty == true
            ? j['sni'] as String
            : null,
        insecure: false,
        alpn: (j['alpn'] as String?)
            ?.split(',')
            .where((e) => e.isNotEmpty)
            .toList(),
        fp: j['fp'] as String?,
      ),
    ...?_wrap(
      'transport',
      _transport(
        j['net'] as String?,
        path: j['path'] as String?,
        host: j['host'] as String?,
        serviceName: j['path'] as String?,
      ),
    ),
  });
}

_Draft? _ssLink(String line) {
  var rest = line.substring('ss://'.length);
  var name = '';
  final hashAt = rest.indexOf('#');
  if (hashAt >= 0) {
    name = Uri.decodeComponent(rest.substring(hashAt + 1));
    rest = rest.substring(0, hashAt);
  }
  String? pluginStr;
  final qAt = rest.indexOf('?');
  if (qAt >= 0) {
    pluginStr = Uri.splitQueryString(rest.substring(qAt + 1))['plugin'];
    rest = rest.substring(0, qAt);
  }
  rest = rest.replaceAll(RegExp(r'/$'), '');

  String userinfo;
  String hostport;
  if (rest.contains('@')) {
    final at = rest.lastIndexOf('@');
    final u = Uri.decodeComponent(rest.substring(0, at));
    userinfo = u.contains(':') ? u : (_tryBase64(u) ?? u);
    hostport = rest.substring(at + 1);
  } else {
    final decoded = _tryBase64(rest);
    if (decoded == null) return null;
    final at = decoded.lastIndexOf('@');
    userinfo = decoded.substring(0, at);
    hostport = decoded.substring(at + 1);
  }
  final colon = userinfo.indexOf(':');
  final pc = hostport.lastIndexOf(':');
  final server = hostport.substring(0, pc).replaceAll(RegExp(r'[\[\]]'), '');
  final port = int.parse(hostport.substring(pc + 1));

  final ob = <String, Object?>{
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    'method': userinfo.substring(0, colon),
    'password': userinfo.substring(colon + 1),
  };
  if (pluginStr != null && pluginStr.isNotEmpty) {
    final parts = pluginStr.split(';');
    if (parts.first != 'obfs-local' && parts.first != 'simple-obfs') {
      return null;
    }
    ob['plugin'] = 'obfs-local';
    ob['plugin_opts'] = parts.skip(1).join(';');
  }
  return _Draft(
    name.isEmpty ? '$server:$port' : name,
    'shadowsocks',
    server,
    port,
    ob,
  );
}

// ------------------------------------------------------------------- helpers

Map<String, Object?> _tls({
  String? sni,
  required bool insecure,
  List<String>? alpn,
  String? fp,
  String? realityKey,
  String? realityShortId,
}) => {
  'enabled': true,
  if (sni != null && sni.isNotEmpty) 'server_name': sni,
  if (insecure) 'insecure': true,
  if (alpn != null && alpn.isNotEmpty) 'alpn': alpn,
  if ((fp != null && fp.isNotEmpty) || realityKey != null)
    'utls': {
      'enabled': true,
      'fingerprint': (fp == null || fp.isEmpty) ? 'chrome' : fp,
    },
  if (realityKey != null)
    'reality': {
      'enabled': true,
      'public_key': realityKey,
      'short_id': ?realityShortId,
    },
};

Map<String, Object?>? _transport(
  String? net, {
  String? path,
  String? host,
  String? serviceName,
}) {
  switch (net) {
    case 'ws':
      return {
        'type': 'ws',
        if (path != null && path.isNotEmpty) 'path': path,
        if (host != null && host.isNotEmpty) 'headers': {'Host': host},
      };
    case 'grpc':
      return {'type': 'grpc', 'service_name': ?serviceName};
    case 'h2':
    case 'http':
      return {
        'type': 'http',
        if (host != null && host.isNotEmpty) 'host': [host],
        if (path != null && path.isNotEmpty) 'path': path,
      };
    case 'httpupgrade':
      return {
        'type': 'httpupgrade',
        if (path != null && path.isNotEmpty) 'path': path,
        if (host != null && host.isNotEmpty) 'host': host,
      };
  }
  return null; // tcp / none
}

Map<String, Object?>? _wrap(String key, Object? value) =>
    value == null ? null : {key: value};

int? _int(Object? v) => v is int ? v : int.tryParse('$v');

String? _tryBase64(String s) {
  var t = s
      .trim()
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll('-', '+')
      .replaceAll('_', '/');
  t = t.padRight((t.length + 3) ~/ 4 * 4, '=');
  try {
    return utf8.decode(base64.decode(t));
  } catch (_) {
    return null;
  }
}

String _hash(String s) => stableHash(s);

/// FNV-1a 32-bit — stable across launches, unlike [String.hashCode].
String stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(s)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
