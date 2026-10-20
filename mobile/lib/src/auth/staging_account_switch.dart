import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

bool isStagingTestToken(String token) {
  try {
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    return claims is Map && claims['fieldrush_staging_actor'] is String;
  } catch (_) {
    return false;
  }
}

/// Preserve the real login on disk. Test sessions exist only in memory, so an
/// app restart returns to the administrator rather than persisting impersonation.
class StagingSessionStorage extends SharedPreferencesLocalStorage {
  StagingSessionStorage()
    : super(persistSessionKey: 'sb-${AppConfig.stagingProjectRef}-auth-token');

  @override
  Future<void> persistSession(String persistSessionString) async {
    final session = jsonDecode(persistSessionString) as Map<String, dynamic>;
    if (isStagingTestToken(session['access_token'] as String)) return;
    await super.persistSession(persistSessionString);
  }
}

class StagingAccountSwitch {
  static Session? _administrator;
  static Timer? _expiry;

  static void clear() {
    _expiry?.cancel();
    _administrator = null;
  }

  static Future<void> switchTo(SupabaseClient client, String profileId) async {
    final config = AppConfig.fromEnvironment();
    if (config.environment != AppEnvironment.staging ||
        Uri.tryParse(config.supabaseUrl)?.host !=
            '${AppConfig.stagingProjectRef}.supabase.co') {
      throw const AuthException(
        'Account switching is only available in staging.',
      );
    }
    final current = client.auth.currentSession;
    if (current == null) {
      throw const AuthException('Sign in as a staging administrator first.');
    }
    if (!isStagingTestToken(current.accessToken)) _administrator = current;
    var administrator = _administrator;
    if (administrator == null) {
      throw const AuthException(
        'Restart the app to return to your administrator account.',
      );
    }
    if (administrator.isExpired) {
      final refreshClient = SupabaseClient(
        config.supabaseUrl,
        config.supabasePublishableKey,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      try {
        administrator = (await refreshClient.auth.setSession(
          administrator.refreshToken!,
        )).session!;
        _administrator = administrator;
        final storage = StagingSessionStorage();
        await storage.initialize();
        await storage.persistSession(jsonEncode(administrator.toJson()));
      } finally {
        await refreshClient.dispose();
      }
    }
    if (profileId == administrator.user.id) {
      _expiry?.cancel();
      await client.auth.recoverSession(jsonEncode(administrator.toJson()));
      return;
    }
    final response = await client.functions.invoke(
      'staging-admin-session',
      headers: {'Authorization': 'Bearer ${administrator.accessToken}'},
      body: {'profile_id': profileId},
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    final session = Session.fromJson(data);
    if (session == null ||
        session.user.id != profileId ||
        session.isExpired ||
        session.refreshToken != null ||
        !isStagingTestToken(session.accessToken)) {
      throw const AuthException(
        'The selected staging session could not be opened.',
      );
    }
    await client.auth.recoverSession(jsonEncode(data));
    _expiry?.cancel();
    _expiry = Timer(
      Duration(
        seconds:
            session.expiresAt! -
            DateTime.now().millisecondsSinceEpoch ~/ 1000 -
            30,
      ),
      () async {
        if (client.auth.currentUser?.id != profileId) return;
        try {
          await switchTo(client, _administrator!.user.id);
        } catch (_) {
          clear();
          await client.auth.signOut(scope: SignOutScope.local);
        }
      },
    );
  }
}
