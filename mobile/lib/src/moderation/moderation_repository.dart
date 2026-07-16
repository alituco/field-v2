import 'package:supabase_flutter/supabase_flutter.dart';

import 'moderation.dart';

abstract class ModerationRepository {
  Future<ModerationStatus> getMyModerationStatus();

  Future<ModerationReportReceipt> submitReport(ModerationReportDraft report);
}

class SupabaseModerationRepository implements ModerationRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<ModerationStatus> getMyModerationStatus() async {
    final response = await _client.rpc('get_my_moderation_status');
    return ModerationStatus.fromRpcResponse(response);
  }

  @override
  Future<ModerationReportReceipt> submitReport(
    ModerationReportDraft report,
  ) async {
    final response = await _client.rpc(
      'submit_moderation_report',
      params: report.toRpcParams(),
    );
    return ModerationReportReceipt.fromRpcResponse(response);
  }
}
