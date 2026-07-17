import 'package:supabase_flutter/supabase_flutter.dart';

import 'reliability.dart';

abstract class ReliabilityRepository {
  Future<ReliabilityStatus> getMyStatus();

  Future<void> submitAppeal({
    required String attendanceRecordId,
    required ReliabilityAppealCategory category,
    required String message,
  });
}

class SupabaseReliabilityRepository implements ReliabilityRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<ReliabilityStatus> getMyStatus() async {
    final response = await _client.rpc('get_my_reliability_status');
    final row = switch (response) {
      final Map value => Map<String, dynamic>.from(value),
      final List value when value.isNotEmpty => Map<String, dynamic>.from(
        value.first as Map,
      ),
      _ => throw StateError('Reliability status is unavailable.'),
    };
    return ReliabilityStatus.fromJson(row);
  }

  @override
  Future<void> submitAppeal({
    required String attendanceRecordId,
    required ReliabilityAppealCategory category,
    required String message,
  }) async {
    await _client.rpc(
      'submit_reliability_appeal',
      params: {
        'attendance_record_id_to_appeal': attendanceRecordId,
        'category_to_use': category.code,
        'message_to_use': message.trim(),
      },
    );
  }
}
