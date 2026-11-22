// Measures subscription links the way the app sees them.
//   dart run bin/report.dart                 # the published subscriptions.json
//   dart run bin/report.dart <url> [<url>…]  # specific links

import 'dart:convert';
import 'dart:io';

import 'package:tunnix_subs/evaluate.dart';

Future<void> main(List<String> args) async {
  final urls = args.isNotEmpty
      ? args
      : [
          for (final s
              in (jsonDecode(File('subscriptions.json').readAsStringSync())
                      as Map)['subscriptions']
                  as List)
            (s as Map)['url'] as String,
        ];
  final http = HttpClient()..userAgent = 'tunnix-subs-finder';
  final cdn = await CdnRanges.load(http);
  final tester = ProxyTester(
    binary: Platform.environment['SINGBOX'] ?? 'sing-box',
  );
  stdout.writeln('CDN ranges loaded: ${cdn.size}');
  stdout.writeln(
    '${'nodes'.padLeft(6)} ${'uniqIP'.padLeft(6)} ${'cdn'.padLeft(5)} '
    '${'work'.padLeft(7)} ${'usable'.padLeft(6)}  link',
  );
  final all = <String>{};
  for (final u in urls) {
    final e = await evaluate(u, http, cdn, tester);
    all.addAll(e.usableIps);
    stdout.writeln(
      '${'${e.nodes}'.padLeft(6)} ${'${e.uniqueIps}'.padLeft(6)} '
      '${'${e.cdn}'.padLeft(5)} ${'${e.working}/${e.tested}'.padLeft(7)} '
      '${'${e.usable}'.padLeft(6)}  ${e.error ?? ''} $u',
    );
  }
  stdout.writeln(
    'Distinct usable IPs across all links (sampled): ${all.length}',
  );
  http.close(force: true);
}
