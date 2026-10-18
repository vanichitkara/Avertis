/// Fetch what the command centre made of one of our reports.
///
/// The app sends a report; the backend turns it into an incident, fuses it
/// with other accounts of the same event, assigns a severity and picks a
/// responder. None of that came back to the person who sent it, who saw
/// only "acknowledged". This closes the loop for them.
library;

import 'package:dio/dio.dart';

class IncidentView {
  const IncidentView({
    required this.incidentId,
    required this.type,
    required this.severity,
    required this.status,
    required this.sourceCount,
    required this.confidence,
    this.peopleAffected,
    this.description,
    this.recommendedResponder,
  });

  final String incidentId;
  final String type;
  final String severity;
  final String status;
  final int sourceCount;
  final double confidence;
  final int? peopleAffected;
  final String? description;
  final String? recommendedResponder;

  /// Other people reported the same event.
  bool get wasFused => sourceCount > 1;
}

class IncidentLookup {
  IncidentLookup({required String baseUrl, String apiKey = ''})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
          headers: {if (apiKey.isNotEmpty) 'X-Avertis-Key': apiKey},
        ));

  final Dio _dio;

  /// Returns null when it cannot be fetched — offline, or the command
  /// centre no longer has it. The caller shows what it already knows
  /// rather than an error, because the report itself is not in doubt.
  Future<IncidentView?> fetch(String incidentId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/incidents/$incidentId',
      );
      final body = response.data;
      if (body == null) return null;

      final incident = body['incident'] as Map<String, dynamic>?;
      if (incident == null) return null;
      final recommendation = body['recommendation'] as Map<String, dynamic>?;

      return IncidentView(
        incidentId: incident['incident_id'] as String? ?? incidentId,
        type: (incident['type'] as String? ?? 'UNKNOWN').replaceAll('_', ' '),
        severity: incident['severity'] as String? ?? 'NORMAL',
        status: incident['status'] as String? ?? 'OPEN',
        sourceCount: (incident['evidence'] as List?)?.length ?? 1,
        confidence: (incident['confidence'] as num?)?.toDouble() ?? 0.0,
        peopleAffected: (incident['people_affected'] as num?)?.toInt(),
        description: incident['description'] as String?,
        recommendedResponder:
            recommendation?['recommended_responder'] as String?,
      );
    } on DioException {
      return null;
    }
  }
}
