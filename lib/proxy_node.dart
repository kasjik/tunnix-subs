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

  /// Where this server really is (IP-geolocated when it was added to the
  /// list). Installed by the app's store; a hook so this file stays plain
  /// Dart, usable outside Flutter (e.g. the subscription finder tool).
  static ServerLocation? Function(ProxyNode node) locationOf = _noLocation;
  static ServerLocation? _noLocation(ProxyNode _) => null;

  /// The subscription's [name] is never shown: free lists label servers
  /// wrongly ("US_34" in Osaka) or with long junk text. Location only.
  ServerLocation? get location => locationOf(this);

  String? get countryCode => location?.countryCode;

  String? get flag {
    final c = countryCode;
    if (c == null || c.length != 2) return null;
    return c.codeUnits
        .map((u) => String.fromCharCode(0x1F1E6 + u - 0x41))
        .join();
  }

  /// Country name, e.g. "Japan".
  String get title {
    final l = location;
    if (l == null) return 'Locating…';
    return countryNames[l.countryCode] ?? l.country ?? l.countryCode;
  }

  /// City, e.g. "Osaka"; empty if unknown.
  String get place => location?.city ?? '';

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

/// A server's real location, from looking up its IP.
class ServerLocation {
  const ServerLocation({
    required this.ip,
    required this.countryCode,
    this.country,
    this.city,
  });

  final String ip;
  final String countryCode;
  final String? country;
  final String? city;

  Map<String, Object?> toJson() => {
    'ip': ip,
    'cc': countryCode,
    'country': ?country,
    'city': ?city,
  };

  static ServerLocation fromJson(Map<String, Object?> j) => ServerLocation(
    ip: j['ip']! as String,
    countryCode: j['cc']! as String,
    country: j['country'] as String?,
    city: j['city'] as String?,
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
