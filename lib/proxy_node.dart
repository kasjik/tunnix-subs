/// One proxy server parsed from a subscription.
///
/// [outbound] is a ready-to-use sing-box outbound object (without `tag`).
class ProxyNode {
  const ProxyNode({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    required this.subscriptionId,
    required this.outbound,
  });

  final String id;
  final String name;

  /// sing-box outbound type: shadowsocks, vmess, trojan, vless, hysteria2.
  final String protocol;
  final String server;
  final int port;
  final String subscriptionId;
  final Map<String, Object?> outbound;

  /// Real country for a server host, if known. Set by the app at startup
  /// (to `ServerGeo.instance.countryOf`); kept as a hook so this file stays
  /// plain Dart, usable outside Flutter (e.g. the subscription finder tool).
  static String? Function(String host) realCountryOf = _none;
  static String? _none(String _) => null;

  static final _flagRe = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);
  static final _codeRe = RegExp(r'^\s*([A-Z]{2})(?=[\s_\-|·.]|\d|$)');

  /// ISO country code: the server's real location when it has been looked
  /// up (see [realCountryOf]), else guessed from the name.
  String? get countryCode =>
      realCountryOf(server) ?? nameCountryCode;

  /// Country the subscription's name claims (flag emoji or "US_" prefix).
  /// Free lists often get this wrong.
  String? get nameCountryCode {
    final m = _flagRe.firstMatch(name);
    if (m != null) {
      return m[0]!.runes
          .map((r) => String.fromCharCode(r - 0x1F1E6 + 0x41))
          .join();
    }
    final c = _codeRe.firstMatch(name)?.group(1);
    return c != null && countryNames.containsKey(c) ? c : null;
  }

  String? get flag {
    final c = countryCode;
    if (c == null) return null;
    return c.codeUnits
        .map((u) => String.fromCharCode(0x1F1E6 + u - 0x41))
        .join();
  }

  /// Country name if known, else the node name.
  String get title {
    final c = countryCode;
    return c == null ? label : (countryNames[c] ?? c);
  }

  /// Node name without its flag emoji. If the name claims a different
  /// country than the server's real one, that claim is dropped too
  /// ("US_34" on a server in Japan → "#34").
  String get label {
    var s = name.replaceAll(_flagRe, '').trim();
    final real = realCountryOf(server);
    final claimed = _codeRe.firstMatch(s)?.group(1);
    if (real != null && claimed != null && claimed != real) {
      s = s.replaceFirst(_codeRe, '').replaceFirst(RegExp(r'^[\s_\-|·.]+'), '');
      if (RegExp(r'^\d+$').hasMatch(s)) s = '#$s';
    }
    return s.isEmpty ? '$server:$port' : s;
  }

  String get protocolLabel => switch (protocol) {
    'shadowsocks' => 'Shadowsocks',
    'vmess' => 'VMess',
    'trojan' => 'Trojan',
    'vless' => 'VLESS',
    'hysteria2' => 'Hysteria2',
    _ => protocol,
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol,
    'server': server,
    'port': port,
    'sub': subscriptionId,
    'outbound': outbound,
  };

  factory ProxyNode.fromJson(Map<String, Object?> j) => ProxyNode(
    id: j['id']! as String,
    name: j['name']! as String,
    protocol: j['protocol']! as String,
    server: j['server']! as String,
    port: j['port']! as int,
    subscriptionId: j['sub']! as String,
    outbound: Map<String, Object?>.from(j['outbound']! as Map),
  );
}

const countryNames = <String, String>{
  'US': 'United States',
  'CA': 'Canada',
  'MX': 'Mexico',
  'BR': 'Brazil',
  'AR': 'Argentina',
  'GB': 'United Kingdom',
  'UK': 'United Kingdom',
  'DE': 'Germany',
  'FR': 'France',
  'NL': 'Netherlands',
  'BE': 'Belgium',
  'CH': 'Switzerland',
  'AT': 'Austria',
  'IT': 'Italy',
  'ES': 'Spain',
  'PT': 'Portugal',
  'IE': 'Ireland',
  'SE': 'Sweden',
  'NO': 'Norway',
  'FI': 'Finland',
  'DK': 'Denmark',
  'PL': 'Poland',
  'CZ': 'Czechia',
  'RO': 'Romania',
  'BG': 'Bulgaria',
  'HU': 'Hungary',
  'UA': 'Ukraine',
  'RU': 'Russia',
  'TR': 'Turkey',
  'IL': 'Israel',
  'AE': 'UAE',
  'SA': 'Saudi Arabia',
  'IN': 'India',
  'PK': 'Pakistan',
  'CN': 'China',
  'HK': 'Hong Kong',
  'TW': 'Taiwan',
  'JP': 'Japan',
  'KR': 'South Korea',
  'SG': 'Singapore',
  'MY': 'Malaysia',
  'TH': 'Thailand',
  'VN': 'Vietnam',
  'ID': 'Indonesia',
  'PH': 'Philippines',
  'AU': 'Australia',
  'NZ': 'New Zealand',
  'ZA': 'South Africa',
  'EG': 'Egypt',
  'KZ': 'Kazakhstan',
  'IR': 'Iran',
  'LT': 'Lithuania',
  'LV': 'Latvia',
  'EE': 'Estonia',
  'LU': 'Luxembourg',
  'IS': 'Iceland',
  'GR': 'Greece',
  'CY': 'Cyprus',
  'MD': 'Moldova',
  'RS': 'Serbia',
  'CL': 'Chile',
  'CO': 'Colombia',
  'PE': 'Peru',
};
