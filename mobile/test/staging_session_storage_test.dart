import 'dart:convert';
import 'package:field/src/auth/staging_account_switch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'temporary staging sessions never replace the persisted administrator',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StagingSessionStorage();
      await storage.initialize();
      final admin = jsonEncode({'access_token': 'normal-admin-token'});
      await storage.persistSession(admin);
      final payload = base64Url.encode(
        utf8.encode(jsonEncode({'fieldrush_staging_actor': 'admin'})),
      );
      final token = 'header.$payload.signature';
      expect(isStagingTestToken(token), isTrue);
      await storage.persistSession(jsonEncode({'access_token': token}));
      expect(await storage.accessToken(), admin);
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
    },
  );
  test('malformed tokens are not recognized as staging test sessions', () {
    for (final token in ['', 'abc', 'a.bad.b']) {
      expect(isStagingTestToken(token), isFalse);
    }
  });
}
