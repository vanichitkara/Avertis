// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'report_store.dart';

// ignore_for_file: type=lint
class $ReportsTable extends Reports with TableInfo<$ReportsTable, Report> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReportsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _reportIdMeta = const VerificationMeta(
    'reportId',
  );
  @override
  late final GeneratedColumn<String> reportId = GeneratedColumn<String>(
    'report_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _packetIdMeta = const VerificationMeta(
    'packetId',
  );
  @override
  late final GeneratedColumn<String> packetId = GeneratedColumn<String>(
    'packet_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<String> priority = GeneratedColumn<String>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _transcriptMeta = const VerificationMeta(
    'transcript',
  );
  @override
  late final GeneratedColumn<String> transcript = GeneratedColumn<String>(
    'transcript',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
    'lat',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lonMeta = const VerificationMeta('lon');
  @override
  late final GeneratedColumn<double> lon = GeneratedColumn<double>(
    'lon',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accuracyMMeta = const VerificationMeta(
    'accuracyM',
  );
  @override
  late final GeneratedColumn<double> accuracyM = GeneratedColumn<double>(
    'accuracy_m',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _peopleCountMeta = const VerificationMeta(
    'peopleCount',
  );
  @override
  late final GeneratedColumn<int> peopleCount = GeneratedColumn<int>(
    'people_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaJsonMeta = const VerificationMeta(
    'mediaJson',
  );
  @override
  late final GeneratedColumn<String> mediaJson = GeneratedColumn<String>(
    'media_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _acknowledgedMeta = const VerificationMeta(
    'acknowledged',
  );
  @override
  late final GeneratedColumn<bool> acknowledged = GeneratedColumn<bool>(
    'acknowledged',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("acknowledged" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _acknowledgedAtMeta = const VerificationMeta(
    'acknowledgedAt',
  );
  @override
  late final GeneratedColumn<DateTime> acknowledgedAt =
      GeneratedColumn<DateTime>(
        'acknowledged_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retransmissionsMeta = const VerificationMeta(
    'retransmissions',
  );
  @override
  late final GeneratedColumn<int> retransmissions = GeneratedColumn<int>(
    'retransmissions',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _incidentIdMeta = const VerificationMeta(
    'incidentId',
  );
  @override
  late final GeneratedColumn<String> incidentId = GeneratedColumn<String>(
    'incident_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    reportId,
    packetId,
    kind,
    priority,
    body,
    transcript,
    lat,
    lon,
    accuracyM,
    peopleCount,
    mediaJson,
    createdAt,
    acknowledged,
    acknowledgedAt,
    retransmissions,
    incidentId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reports';
  @override
  VerificationContext validateIntegrity(
    Insertable<Report> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('report_id')) {
      context.handle(
        _reportIdMeta,
        reportId.isAcceptableOrUnknown(data['report_id']!, _reportIdMeta),
      );
    } else if (isInserting) {
      context.missing(_reportIdMeta);
    }
    if (data.containsKey('packet_id')) {
      context.handle(
        _packetIdMeta,
        packetId.isAcceptableOrUnknown(data['packet_id']!, _packetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_packetIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    } else if (isInserting) {
      context.missing(_priorityMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    }
    if (data.containsKey('transcript')) {
      context.handle(
        _transcriptMeta,
        transcript.isAcceptableOrUnknown(data['transcript']!, _transcriptMeta),
      );
    }
    if (data.containsKey('lat')) {
      context.handle(
        _latMeta,
        lat.isAcceptableOrUnknown(data['lat']!, _latMeta),
      );
    }
    if (data.containsKey('lon')) {
      context.handle(
        _lonMeta,
        lon.isAcceptableOrUnknown(data['lon']!, _lonMeta),
      );
    }
    if (data.containsKey('accuracy_m')) {
      context.handle(
        _accuracyMMeta,
        accuracyM.isAcceptableOrUnknown(data['accuracy_m']!, _accuracyMMeta),
      );
    }
    if (data.containsKey('people_count')) {
      context.handle(
        _peopleCountMeta,
        peopleCount.isAcceptableOrUnknown(
          data['people_count']!,
          _peopleCountMeta,
        ),
      );
    }
    if (data.containsKey('media_json')) {
      context.handle(
        _mediaJsonMeta,
        mediaJson.isAcceptableOrUnknown(data['media_json']!, _mediaJsonMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('acknowledged')) {
      context.handle(
        _acknowledgedMeta,
        acknowledged.isAcceptableOrUnknown(
          data['acknowledged']!,
          _acknowledgedMeta,
        ),
      );
    }
    if (data.containsKey('acknowledged_at')) {
      context.handle(
        _acknowledgedAtMeta,
        acknowledgedAt.isAcceptableOrUnknown(
          data['acknowledged_at']!,
          _acknowledgedAtMeta,
        ),
      );
    }
    if (data.containsKey('retransmissions')) {
      context.handle(
        _retransmissionsMeta,
        retransmissions.isAcceptableOrUnknown(
          data['retransmissions']!,
          _retransmissionsMeta,
        ),
      );
    }
    if (data.containsKey('incident_id')) {
      context.handle(
        _incidentIdMeta,
        incidentId.isAcceptableOrUnknown(data['incident_id']!, _incidentIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {reportId};
  @override
  Report map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Report(
      reportId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}report_id'],
      )!,
      packetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}packet_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}priority'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      ),
      transcript: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcript'],
      ),
      lat: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}lat'],
      ),
      lon: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}lon'],
      ),
      accuracyM: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}accuracy_m'],
      ),
      peopleCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}people_count'],
      ),
      mediaJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      acknowledged: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}acknowledged'],
      )!,
      acknowledgedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}acknowledged_at'],
      ),
      retransmissions: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retransmissions'],
      )!,
      incidentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}incident_id'],
      ),
    );
  }

  @override
  $ReportsTable createAlias(String alias) {
    return $ReportsTable(attachedDatabase, alias);
  }
}

class Report extends DataClass implements Insertable<Report> {
  final String reportId;
  final String packetId;
  final String kind;
  final String priority;
  final String? body;
  final String? transcript;
  final double? lat;
  final double? lon;
  final double? accuracyM;
  final int? peopleCount;
  final String mediaJson;
  final DateTime createdAt;

  /// Local delivery state — what this device actually knows.
  final bool acknowledged;
  final DateTime? acknowledgedAt;
  final int retransmissions;

  /// Assigned by the backend once it has been synced through a gateway.
  final String? incidentId;
  const Report({
    required this.reportId,
    required this.packetId,
    required this.kind,
    required this.priority,
    this.body,
    this.transcript,
    this.lat,
    this.lon,
    this.accuracyM,
    this.peopleCount,
    required this.mediaJson,
    required this.createdAt,
    required this.acknowledged,
    this.acknowledgedAt,
    required this.retransmissions,
    this.incidentId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['report_id'] = Variable<String>(reportId);
    map['packet_id'] = Variable<String>(packetId);
    map['kind'] = Variable<String>(kind);
    map['priority'] = Variable<String>(priority);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    if (!nullToAbsent || transcript != null) {
      map['transcript'] = Variable<String>(transcript);
    }
    if (!nullToAbsent || lat != null) {
      map['lat'] = Variable<double>(lat);
    }
    if (!nullToAbsent || lon != null) {
      map['lon'] = Variable<double>(lon);
    }
    if (!nullToAbsent || accuracyM != null) {
      map['accuracy_m'] = Variable<double>(accuracyM);
    }
    if (!nullToAbsent || peopleCount != null) {
      map['people_count'] = Variable<int>(peopleCount);
    }
    map['media_json'] = Variable<String>(mediaJson);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['acknowledged'] = Variable<bool>(acknowledged);
    if (!nullToAbsent || acknowledgedAt != null) {
      map['acknowledged_at'] = Variable<DateTime>(acknowledgedAt);
    }
    map['retransmissions'] = Variable<int>(retransmissions);
    if (!nullToAbsent || incidentId != null) {
      map['incident_id'] = Variable<String>(incidentId);
    }
    return map;
  }

  ReportsCompanion toCompanion(bool nullToAbsent) {
    return ReportsCompanion(
      reportId: Value(reportId),
      packetId: Value(packetId),
      kind: Value(kind),
      priority: Value(priority),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      transcript: transcript == null && nullToAbsent
          ? const Value.absent()
          : Value(transcript),
      lat: lat == null && nullToAbsent ? const Value.absent() : Value(lat),
      lon: lon == null && nullToAbsent ? const Value.absent() : Value(lon),
      accuracyM: accuracyM == null && nullToAbsent
          ? const Value.absent()
          : Value(accuracyM),
      peopleCount: peopleCount == null && nullToAbsent
          ? const Value.absent()
          : Value(peopleCount),
      mediaJson: Value(mediaJson),
      createdAt: Value(createdAt),
      acknowledged: Value(acknowledged),
      acknowledgedAt: acknowledgedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(acknowledgedAt),
      retransmissions: Value(retransmissions),
      incidentId: incidentId == null && nullToAbsent
          ? const Value.absent()
          : Value(incidentId),
    );
  }

  factory Report.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Report(
      reportId: serializer.fromJson<String>(json['reportId']),
      packetId: serializer.fromJson<String>(json['packetId']),
      kind: serializer.fromJson<String>(json['kind']),
      priority: serializer.fromJson<String>(json['priority']),
      body: serializer.fromJson<String?>(json['body']),
      transcript: serializer.fromJson<String?>(json['transcript']),
      lat: serializer.fromJson<double?>(json['lat']),
      lon: serializer.fromJson<double?>(json['lon']),
      accuracyM: serializer.fromJson<double?>(json['accuracyM']),
      peopleCount: serializer.fromJson<int?>(json['peopleCount']),
      mediaJson: serializer.fromJson<String>(json['mediaJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      acknowledged: serializer.fromJson<bool>(json['acknowledged']),
      acknowledgedAt: serializer.fromJson<DateTime?>(json['acknowledgedAt']),
      retransmissions: serializer.fromJson<int>(json['retransmissions']),
      incidentId: serializer.fromJson<String?>(json['incidentId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'reportId': serializer.toJson<String>(reportId),
      'packetId': serializer.toJson<String>(packetId),
      'kind': serializer.toJson<String>(kind),
      'priority': serializer.toJson<String>(priority),
      'body': serializer.toJson<String?>(body),
      'transcript': serializer.toJson<String?>(transcript),
      'lat': serializer.toJson<double?>(lat),
      'lon': serializer.toJson<double?>(lon),
      'accuracyM': serializer.toJson<double?>(accuracyM),
      'peopleCount': serializer.toJson<int?>(peopleCount),
      'mediaJson': serializer.toJson<String>(mediaJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'acknowledged': serializer.toJson<bool>(acknowledged),
      'acknowledgedAt': serializer.toJson<DateTime?>(acknowledgedAt),
      'retransmissions': serializer.toJson<int>(retransmissions),
      'incidentId': serializer.toJson<String?>(incidentId),
    };
  }

  Report copyWith({
    String? reportId,
    String? packetId,
    String? kind,
    String? priority,
    Value<String?> body = const Value.absent(),
    Value<String?> transcript = const Value.absent(),
    Value<double?> lat = const Value.absent(),
    Value<double?> lon = const Value.absent(),
    Value<double?> accuracyM = const Value.absent(),
    Value<int?> peopleCount = const Value.absent(),
    String? mediaJson,
    DateTime? createdAt,
    bool? acknowledged,
    Value<DateTime?> acknowledgedAt = const Value.absent(),
    int? retransmissions,
    Value<String?> incidentId = const Value.absent(),
  }) => Report(
    reportId: reportId ?? this.reportId,
    packetId: packetId ?? this.packetId,
    kind: kind ?? this.kind,
    priority: priority ?? this.priority,
    body: body.present ? body.value : this.body,
    transcript: transcript.present ? transcript.value : this.transcript,
    lat: lat.present ? lat.value : this.lat,
    lon: lon.present ? lon.value : this.lon,
    accuracyM: accuracyM.present ? accuracyM.value : this.accuracyM,
    peopleCount: peopleCount.present ? peopleCount.value : this.peopleCount,
    mediaJson: mediaJson ?? this.mediaJson,
    createdAt: createdAt ?? this.createdAt,
    acknowledged: acknowledged ?? this.acknowledged,
    acknowledgedAt: acknowledgedAt.present
        ? acknowledgedAt.value
        : this.acknowledgedAt,
    retransmissions: retransmissions ?? this.retransmissions,
    incidentId: incidentId.present ? incidentId.value : this.incidentId,
  );
  Report copyWithCompanion(ReportsCompanion data) {
    return Report(
      reportId: data.reportId.present ? data.reportId.value : this.reportId,
      packetId: data.packetId.present ? data.packetId.value : this.packetId,
      kind: data.kind.present ? data.kind.value : this.kind,
      priority: data.priority.present ? data.priority.value : this.priority,
      body: data.body.present ? data.body.value : this.body,
      transcript: data.transcript.present
          ? data.transcript.value
          : this.transcript,
      lat: data.lat.present ? data.lat.value : this.lat,
      lon: data.lon.present ? data.lon.value : this.lon,
      accuracyM: data.accuracyM.present ? data.accuracyM.value : this.accuracyM,
      peopleCount: data.peopleCount.present
          ? data.peopleCount.value
          : this.peopleCount,
      mediaJson: data.mediaJson.present ? data.mediaJson.value : this.mediaJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      acknowledged: data.acknowledged.present
          ? data.acknowledged.value
          : this.acknowledged,
      acknowledgedAt: data.acknowledgedAt.present
          ? data.acknowledgedAt.value
          : this.acknowledgedAt,
      retransmissions: data.retransmissions.present
          ? data.retransmissions.value
          : this.retransmissions,
      incidentId: data.incidentId.present
          ? data.incidentId.value
          : this.incidentId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Report(')
          ..write('reportId: $reportId, ')
          ..write('packetId: $packetId, ')
          ..write('kind: $kind, ')
          ..write('priority: $priority, ')
          ..write('body: $body, ')
          ..write('transcript: $transcript, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('accuracyM: $accuracyM, ')
          ..write('peopleCount: $peopleCount, ')
          ..write('mediaJson: $mediaJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('acknowledged: $acknowledged, ')
          ..write('acknowledgedAt: $acknowledgedAt, ')
          ..write('retransmissions: $retransmissions, ')
          ..write('incidentId: $incidentId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    reportId,
    packetId,
    kind,
    priority,
    body,
    transcript,
    lat,
    lon,
    accuracyM,
    peopleCount,
    mediaJson,
    createdAt,
    acknowledged,
    acknowledgedAt,
    retransmissions,
    incidentId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Report &&
          other.reportId == this.reportId &&
          other.packetId == this.packetId &&
          other.kind == this.kind &&
          other.priority == this.priority &&
          other.body == this.body &&
          other.transcript == this.transcript &&
          other.lat == this.lat &&
          other.lon == this.lon &&
          other.accuracyM == this.accuracyM &&
          other.peopleCount == this.peopleCount &&
          other.mediaJson == this.mediaJson &&
          other.createdAt == this.createdAt &&
          other.acknowledged == this.acknowledged &&
          other.acknowledgedAt == this.acknowledgedAt &&
          other.retransmissions == this.retransmissions &&
          other.incidentId == this.incidentId);
}

class ReportsCompanion extends UpdateCompanion<Report> {
  final Value<String> reportId;
  final Value<String> packetId;
  final Value<String> kind;
  final Value<String> priority;
  final Value<String?> body;
  final Value<String?> transcript;
  final Value<double?> lat;
  final Value<double?> lon;
  final Value<double?> accuracyM;
  final Value<int?> peopleCount;
  final Value<String> mediaJson;
  final Value<DateTime> createdAt;
  final Value<bool> acknowledged;
  final Value<DateTime?> acknowledgedAt;
  final Value<int> retransmissions;
  final Value<String?> incidentId;
  final Value<int> rowid;
  const ReportsCompanion({
    this.reportId = const Value.absent(),
    this.packetId = const Value.absent(),
    this.kind = const Value.absent(),
    this.priority = const Value.absent(),
    this.body = const Value.absent(),
    this.transcript = const Value.absent(),
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.accuracyM = const Value.absent(),
    this.peopleCount = const Value.absent(),
    this.mediaJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.acknowledged = const Value.absent(),
    this.acknowledgedAt = const Value.absent(),
    this.retransmissions = const Value.absent(),
    this.incidentId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReportsCompanion.insert({
    required String reportId,
    required String packetId,
    required String kind,
    required String priority,
    this.body = const Value.absent(),
    this.transcript = const Value.absent(),
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.accuracyM = const Value.absent(),
    this.peopleCount = const Value.absent(),
    this.mediaJson = const Value.absent(),
    required DateTime createdAt,
    this.acknowledged = const Value.absent(),
    this.acknowledgedAt = const Value.absent(),
    this.retransmissions = const Value.absent(),
    this.incidentId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : reportId = Value(reportId),
       packetId = Value(packetId),
       kind = Value(kind),
       priority = Value(priority),
       createdAt = Value(createdAt);
  static Insertable<Report> custom({
    Expression<String>? reportId,
    Expression<String>? packetId,
    Expression<String>? kind,
    Expression<String>? priority,
    Expression<String>? body,
    Expression<String>? transcript,
    Expression<double>? lat,
    Expression<double>? lon,
    Expression<double>? accuracyM,
    Expression<int>? peopleCount,
    Expression<String>? mediaJson,
    Expression<DateTime>? createdAt,
    Expression<bool>? acknowledged,
    Expression<DateTime>? acknowledgedAt,
    Expression<int>? retransmissions,
    Expression<String>? incidentId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (reportId != null) 'report_id': reportId,
      if (packetId != null) 'packet_id': packetId,
      if (kind != null) 'kind': kind,
      if (priority != null) 'priority': priority,
      if (body != null) 'body': body,
      if (transcript != null) 'transcript': transcript,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (accuracyM != null) 'accuracy_m': accuracyM,
      if (peopleCount != null) 'people_count': peopleCount,
      if (mediaJson != null) 'media_json': mediaJson,
      if (createdAt != null) 'created_at': createdAt,
      if (acknowledged != null) 'acknowledged': acknowledged,
      if (acknowledgedAt != null) 'acknowledged_at': acknowledgedAt,
      if (retransmissions != null) 'retransmissions': retransmissions,
      if (incidentId != null) 'incident_id': incidentId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReportsCompanion copyWith({
    Value<String>? reportId,
    Value<String>? packetId,
    Value<String>? kind,
    Value<String>? priority,
    Value<String?>? body,
    Value<String?>? transcript,
    Value<double?>? lat,
    Value<double?>? lon,
    Value<double?>? accuracyM,
    Value<int?>? peopleCount,
    Value<String>? mediaJson,
    Value<DateTime>? createdAt,
    Value<bool>? acknowledged,
    Value<DateTime?>? acknowledgedAt,
    Value<int>? retransmissions,
    Value<String?>? incidentId,
    Value<int>? rowid,
  }) {
    return ReportsCompanion(
      reportId: reportId ?? this.reportId,
      packetId: packetId ?? this.packetId,
      kind: kind ?? this.kind,
      priority: priority ?? this.priority,
      body: body ?? this.body,
      transcript: transcript ?? this.transcript,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      accuracyM: accuracyM ?? this.accuracyM,
      peopleCount: peopleCount ?? this.peopleCount,
      mediaJson: mediaJson ?? this.mediaJson,
      createdAt: createdAt ?? this.createdAt,
      acknowledged: acknowledged ?? this.acknowledged,
      acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
      retransmissions: retransmissions ?? this.retransmissions,
      incidentId: incidentId ?? this.incidentId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (reportId.present) {
      map['report_id'] = Variable<String>(reportId.value);
    }
    if (packetId.present) {
      map['packet_id'] = Variable<String>(packetId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (priority.present) {
      map['priority'] = Variable<String>(priority.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (transcript.present) {
      map['transcript'] = Variable<String>(transcript.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lon.present) {
      map['lon'] = Variable<double>(lon.value);
    }
    if (accuracyM.present) {
      map['accuracy_m'] = Variable<double>(accuracyM.value);
    }
    if (peopleCount.present) {
      map['people_count'] = Variable<int>(peopleCount.value);
    }
    if (mediaJson.present) {
      map['media_json'] = Variable<String>(mediaJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (acknowledged.present) {
      map['acknowledged'] = Variable<bool>(acknowledged.value);
    }
    if (acknowledgedAt.present) {
      map['acknowledged_at'] = Variable<DateTime>(acknowledgedAt.value);
    }
    if (retransmissions.present) {
      map['retransmissions'] = Variable<int>(retransmissions.value);
    }
    if (incidentId.present) {
      map['incident_id'] = Variable<String>(incidentId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReportsCompanion(')
          ..write('reportId: $reportId, ')
          ..write('packetId: $packetId, ')
          ..write('kind: $kind, ')
          ..write('priority: $priority, ')
          ..write('body: $body, ')
          ..write('transcript: $transcript, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('accuracyM: $accuracyM, ')
          ..write('peopleCount: $peopleCount, ')
          ..write('mediaJson: $mediaJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('acknowledged: $acknowledged, ')
          ..write('acknowledgedAt: $acknowledgedAt, ')
          ..write('retransmissions: $retransmissions, ')
          ..write('incidentId: $incidentId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ReportDatabase extends GeneratedDatabase {
  _$ReportDatabase(QueryExecutor e) : super(e);
  $ReportDatabaseManager get managers => $ReportDatabaseManager(this);
  late final $ReportsTable reports = $ReportsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [reports];
}

typedef $$ReportsTableCreateCompanionBuilder =
    ReportsCompanion Function({
      required String reportId,
      required String packetId,
      required String kind,
      required String priority,
      Value<String?> body,
      Value<String?> transcript,
      Value<double?> lat,
      Value<double?> lon,
      Value<double?> accuracyM,
      Value<int?> peopleCount,
      Value<String> mediaJson,
      required DateTime createdAt,
      Value<bool> acknowledged,
      Value<DateTime?> acknowledgedAt,
      Value<int> retransmissions,
      Value<String?> incidentId,
      Value<int> rowid,
    });
typedef $$ReportsTableUpdateCompanionBuilder =
    ReportsCompanion Function({
      Value<String> reportId,
      Value<String> packetId,
      Value<String> kind,
      Value<String> priority,
      Value<String?> body,
      Value<String?> transcript,
      Value<double?> lat,
      Value<double?> lon,
      Value<double?> accuracyM,
      Value<int?> peopleCount,
      Value<String> mediaJson,
      Value<DateTime> createdAt,
      Value<bool> acknowledged,
      Value<DateTime?> acknowledgedAt,
      Value<int> retransmissions,
      Value<String?> incidentId,
      Value<int> rowid,
    });

class $$ReportsTableFilterComposer
    extends Composer<_$ReportDatabase, $ReportsTable> {
  $$ReportsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get reportId => $composableBuilder(
    column: $table.reportId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get packetId => $composableBuilder(
    column: $table.packetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get lat => $composableBuilder(
    column: $table.lat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get lon => $composableBuilder(
    column: $table.lon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get accuracyM => $composableBuilder(
    column: $table.accuracyM,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get peopleCount => $composableBuilder(
    column: $table.peopleCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaJson => $composableBuilder(
    column: $table.mediaJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get acknowledgedAt => $composableBuilder(
    column: $table.acknowledgedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retransmissions => $composableBuilder(
    column: $table.retransmissions,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get incidentId => $composableBuilder(
    column: $table.incidentId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReportsTableOrderingComposer
    extends Composer<_$ReportDatabase, $ReportsTable> {
  $$ReportsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get reportId => $composableBuilder(
    column: $table.reportId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get packetId => $composableBuilder(
    column: $table.packetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get lat => $composableBuilder(
    column: $table.lat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get lon => $composableBuilder(
    column: $table.lon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get accuracyM => $composableBuilder(
    column: $table.accuracyM,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get peopleCount => $composableBuilder(
    column: $table.peopleCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaJson => $composableBuilder(
    column: $table.mediaJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get acknowledgedAt => $composableBuilder(
    column: $table.acknowledgedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retransmissions => $composableBuilder(
    column: $table.retransmissions,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get incidentId => $composableBuilder(
    column: $table.incidentId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReportsTableAnnotationComposer
    extends Composer<_$ReportDatabase, $ReportsTable> {
  $$ReportsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get reportId =>
      $composableBuilder(column: $table.reportId, builder: (column) => column);

  GeneratedColumn<String> get packetId =>
      $composableBuilder(column: $table.packetId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => column,
  );

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lon =>
      $composableBuilder(column: $table.lon, builder: (column) => column);

  GeneratedColumn<double> get accuracyM =>
      $composableBuilder(column: $table.accuracyM, builder: (column) => column);

  GeneratedColumn<int> get peopleCount => $composableBuilder(
    column: $table.peopleCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mediaJson =>
      $composableBuilder(column: $table.mediaJson, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get acknowledged => $composableBuilder(
    column: $table.acknowledged,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get acknowledgedAt => $composableBuilder(
    column: $table.acknowledgedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retransmissions => $composableBuilder(
    column: $table.retransmissions,
    builder: (column) => column,
  );

  GeneratedColumn<String> get incidentId => $composableBuilder(
    column: $table.incidentId,
    builder: (column) => column,
  );
}

class $$ReportsTableTableManager
    extends
        RootTableManager<
          _$ReportDatabase,
          $ReportsTable,
          Report,
          $$ReportsTableFilterComposer,
          $$ReportsTableOrderingComposer,
          $$ReportsTableAnnotationComposer,
          $$ReportsTableCreateCompanionBuilder,
          $$ReportsTableUpdateCompanionBuilder,
          (Report, BaseReferences<_$ReportDatabase, $ReportsTable, Report>),
          Report,
          PrefetchHooks Function()
        > {
  $$ReportsTableTableManager(_$ReportDatabase db, $ReportsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReportsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReportsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReportsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> reportId = const Value.absent(),
                Value<String> packetId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> priority = const Value.absent(),
                Value<String?> body = const Value.absent(),
                Value<String?> transcript = const Value.absent(),
                Value<double?> lat = const Value.absent(),
                Value<double?> lon = const Value.absent(),
                Value<double?> accuracyM = const Value.absent(),
                Value<int?> peopleCount = const Value.absent(),
                Value<String> mediaJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<bool> acknowledged = const Value.absent(),
                Value<DateTime?> acknowledgedAt = const Value.absent(),
                Value<int> retransmissions = const Value.absent(),
                Value<String?> incidentId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReportsCompanion(
                reportId: reportId,
                packetId: packetId,
                kind: kind,
                priority: priority,
                body: body,
                transcript: transcript,
                lat: lat,
                lon: lon,
                accuracyM: accuracyM,
                peopleCount: peopleCount,
                mediaJson: mediaJson,
                createdAt: createdAt,
                acknowledged: acknowledged,
                acknowledgedAt: acknowledgedAt,
                retransmissions: retransmissions,
                incidentId: incidentId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String reportId,
                required String packetId,
                required String kind,
                required String priority,
                Value<String?> body = const Value.absent(),
                Value<String?> transcript = const Value.absent(),
                Value<double?> lat = const Value.absent(),
                Value<double?> lon = const Value.absent(),
                Value<double?> accuracyM = const Value.absent(),
                Value<int?> peopleCount = const Value.absent(),
                Value<String> mediaJson = const Value.absent(),
                required DateTime createdAt,
                Value<bool> acknowledged = const Value.absent(),
                Value<DateTime?> acknowledgedAt = const Value.absent(),
                Value<int> retransmissions = const Value.absent(),
                Value<String?> incidentId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReportsCompanion.insert(
                reportId: reportId,
                packetId: packetId,
                kind: kind,
                priority: priority,
                body: body,
                transcript: transcript,
                lat: lat,
                lon: lon,
                accuracyM: accuracyM,
                peopleCount: peopleCount,
                mediaJson: mediaJson,
                createdAt: createdAt,
                acknowledged: acknowledged,
                acknowledgedAt: acknowledgedAt,
                retransmissions: retransmissions,
                incidentId: incidentId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReportsTableProcessedTableManager =
    ProcessedTableManager<
      _$ReportDatabase,
      $ReportsTable,
      Report,
      $$ReportsTableFilterComposer,
      $$ReportsTableOrderingComposer,
      $$ReportsTableAnnotationComposer,
      $$ReportsTableCreateCompanionBuilder,
      $$ReportsTableUpdateCompanionBuilder,
      (Report, BaseReferences<_$ReportDatabase, $ReportsTable, Report>),
      Report,
      PrefetchHooks Function()
    >;

class $ReportDatabaseManager {
  final _$ReportDatabase _db;
  $ReportDatabaseManager(this._db);
  $$ReportsTableTableManager get reports =>
      $$ReportsTableTableManager(_db, _db.reports);
}
