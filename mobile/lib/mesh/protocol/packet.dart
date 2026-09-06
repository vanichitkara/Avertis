/// Avertis mesh protocol — Dart implementation.
///
/// This is the on-device half of the frozen contract in docs/protocol.md. It
/// must serialise byte-for-byte identically to the Python implementation in
/// simulator/avertis_sim/protocol.py; docs/fixtures/protocol_fixtures.json
/// pins the expected output and test/protocol_conformance_test.dart checks it.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

export '../relay_policy.dart' show relayScore;

const String protocolVersion = '1.0';
const int maxPath = 16;
const String broadcast = '*';
const String anyGateway = 'gateway';

enum MessageType {
  hello('HELLO'),
  nodeStatus('NODE_STATUS'),
  incident('INCIDENT'),
  sos('SOS'),
  ack('ACK'),
  routeRequest('ROUTE_REQUEST'),
  routeResponse('ROUTE_RESPONSE'),
  gatewayAvailable('GATEWAY_AVAILABLE'),
  sync('SYNC'),
  syncAck('SYNC_ACK');

  const MessageType(this.wire);
  final String wire;

  static MessageType fromWire(String value) => MessageType.values.firstWhere(
        (t) => t.wire == value,
        orElse: () => throw ArgumentError('unknown message_type: $value'),
      );
}

enum Priority {
  lifeCritical('LIFE_CRITICAL', 0, 10),
  emergency('EMERGENCY', 1, 8),
  operational('OPERATIONAL', 2, 6),
  normal('NORMAL', 3, 4);

  const Priority(this.wire, this.rank, this.defaultTtl);

  final String wire;

  /// Lower sorts first — queues and critical-first sync both use this.
  final int rank;
  final int defaultTtl;

  static Priority fromWire(String value) => Priority.values.firstWhere(
        (p) => p.wire == value,
        orElse: () => throw ArgumentError('unknown priority: $value'),
      );
}

enum NodeRole {
  survivor('SURVIVOR'),
  responder('RESPONDER'),
  relay('RELAY'),
  gateway('GATEWAY');

  const NodeRole(this.wire);
  final String wire;

  static NodeRole fromWire(String value) => NodeRole.values.firstWhere(
        (r) => r.wire == value,
        orElse: () => NodeRole.survivor,
      );
}

/// Canonical JSON: keys sorted, no whitespace, UTF-8, non-ASCII not escaped.
/// Must match Python's `json.dumps(sort_keys=True, separators=(',',':'),
/// ensure_ascii=False)` exactly — see docs/protocol.md §2.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(buffer, value);
  return buffer.toString();
}

void _writeCanonical(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is num) {
    out.write(_canonicalNumber(value));
  } else if (value is String) {
    out.write(_canonicalString(value));
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(out, value[i]);
    }
    out.write(']');
  } else if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      out.write(_canonicalString(keys[i]));
      out.write(':');
      _writeCanonical(out, value[keys[i]]);
    }
    out.write('}');
  } else {
    throw ArgumentError('not JSON-encodable: ${value.runtimeType}');
  }
}

/// Python renders whole doubles as `1.0` and ints as `1`; Dart's `toString`
/// agrees, but `1.0.toString()` is `1.0` while `(1.0).toInt()` would not be.
/// Keep the distinction the payload was built with.
String _canonicalNumber(num value) {
  if (value is int) return value.toString();
  final d = value as double;
  if (d.isNaN || d.isInfinite) {
    throw ArgumentError('non-finite numbers are not permitted on the wire');
  }
  // Dart prints 1.0 as "1.0" and 0.67 as "0.67", matching Python's repr for
  // the values this protocol carries.
  return d.toString();
}

String _canonicalString(String value) {
  final out = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (rune < 0x20) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  out.write('"');
  return out.toString();
}

/// sha256 of the canonical payload, first 16 hex characters.
String payloadHashOf(Map<String, dynamic> payload) {
  final bytes = utf8.encode(canonicalJson(payload));
  return sha256.convert(bytes).toString().substring(0, 16);
}

/// ISO-8601 UTC with millisecond precision and a `Z` suffix.
String isoOf(DateTime ts) {
  final utc = ts.toUtc();
  final s = utc.toIso8601String();
  // Dart emits either `...T12:00:00.000Z` or `...T12:00:00.000000Z`.
  final match = RegExp(r'^(.*T\d{2}:\d{2}:\d{2})\.(\d{3})\d*Z?$').firstMatch(s);
  if (match == null) return '${utc.toIso8601String()}Z';
  return '${match.group(1)}.${match.group(2)}Z';
}

DateTime parseIso(String value) => DateTime.parse(value).toUtc();

class GeoPoint {
  const GeoPoint(this.lat, this.lon, {this.accuracyM = 10.0});

  final double lat;
  final double lon;
  final double accuracyM;

  Map<String, dynamic> toJson() =>
      {'lat': lat, 'lon': lon, 'accuracy_m': accuracyM};

  static GeoPoint? fromJson(Map<String, dynamic>? json) => json == null
      ? null
      : GeoPoint(
          (json['lat'] as num).toDouble(),
          (json['lon'] as num).toDouble(),
          accuracyM: (json['accuracy_m'] as num?)?.toDouble() ?? 10.0,
        );
}

/// One packet on the wire. Immutable — forwarding produces a new instance.
class Packet {
  const Packet({
    required this.packetId,
    required this.originNode,
    required this.destination,
    required this.messageType,
    required this.priority,
    required this.ttl,
    required this.hopCount,
    required this.createdAt,
    this.payload = const {},
    this.path = const [],
  });

  factory Packet.create({
    required String packetId,
    required String originNode,
    required String destination,
    required MessageType messageType,
    required Priority priority,
    required DateTime createdAt,
    Map<String, dynamic> payload = const {},
    int? ttl,
  }) {
    return Packet(
      packetId: packetId,
      originNode: originNode,
      destination: destination,
      messageType: messageType,
      priority: priority,
      // HELLO is a link-local beacon and is never forwarded.
      ttl: messageType == MessageType.hello ? 1 : (ttl ?? priority.defaultTtl),
      hopCount: 0,
      createdAt: createdAt,
      payload: payload,
      path: const [],
    );
  }

  final String packetId;
  final String originNode;
  final String destination;
  final MessageType messageType;
  final Priority priority;
  final int ttl;
  final int hopCount;
  final DateTime createdAt;
  final Map<String, dynamic> payload;
  final List<String> path;

  String get payloadHash => payloadHashOf(payload);

  /// The copy a relay puts back on the wire. See docs/protocol.md §6.
  Packet forwardedBy(String nodeId) {
    var newPath = [...path, nodeId];
    if (newPath.length > maxPath) {
      newPath = newPath.sublist(newPath.length - maxPath);
    }
    return Packet(
      packetId: packetId,
      originNode: originNode,
      destination: destination,
      messageType: messageType,
      priority: priority,
      ttl: ttl - 1,
      hopCount: hopCount + 1,
      createdAt: createdAt,
      payload: payload,
      path: newPath,
    );
  }

  Map<String, dynamic> toJson() => {
        'packet_id': packetId,
        'origin_node': originNode,
        'destination': destination,
        'message_type': messageType.wire,
        'priority': priority.wire,
        'ttl': ttl,
        'hop_count': hopCount,
        'created_at': isoOf(createdAt),
        'payload_hash': payloadHash,
        'path': path,
        'payload': payload,
      };

  static Packet fromJson(Map<String, dynamic> json) => Packet(
        packetId: json['packet_id'] as String,
        originNode: json['origin_node'] as String,
        destination: json['destination'] as String,
        messageType: MessageType.fromWire(json['message_type'] as String),
        priority: Priority.fromWire(json['priority'] as String),
        ttl: json['ttl'] as int,
        hopCount: json['hop_count'] as int,
        createdAt: parseIso(json['created_at'] as String),
        payload: Map<String, dynamic>.from(
            (json['payload'] as Map?) ?? const <String, dynamic>{}),
        path: List<String>.from((json['path'] as List?) ?? const []),
      );

  List<int> encode() => utf8.encode(canonicalJson(toJson()));

  static Packet decode(List<int> raw) =>
      Packet.fromJson(jsonDecode(utf8.decode(raw)) as Map<String, dynamic>);

  bool integrityOk(String claimedHash) => payloadHash == claimedHash;

  @override
  String toString() =>
      'Packet($packetId ${messageType.wire} ${priority.wire} ttl=$ttl '
      'hops=$hopCount $originNode→$destination)';
}
