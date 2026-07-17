import 'package:supabase_flutter/supabase_flutter.dart';

import 'support.dart';

abstract class SupportRepository {
  Future<SupportRequestReceipt> submitRequest(SupportRequestDraft request);
}

class SupabaseSupportRepository implements SupportRepository {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<SupportRequestReceipt> submitRequest(
    SupportRequestDraft request,
  ) async {
    final response = await _client.rpc(
      'submit_support_ticket',
      params: request.toRpcParams(),
    );
    return SupportRequestReceipt.fromRpcResponse(response);
  }
}
