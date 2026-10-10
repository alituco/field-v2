import 'dart:async';
import 'dart:convert';

import 'package:field/src/profile/fieldrush_you_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final walletJson = <String, dynamic>{
    'currency': 'USD',
    'balance_fils': 6505,
    'balances': [
      {'currency': 'USD', 'balance_fils': 6505},
      {'currency': 'BHD', 'balance_fils': 1234},
    ],
  };

  test(
    'preferences keep exactly the six supported keys and copy immutably',
    () {
      const original = YouNotificationPreferences();
      final changed = original.copyWith(
        gameReminders: false,
        newsAndOffers: true,
      );
      expect(original.gameReminders, isTrue);
      expect(original.newsAndOffers, isFalse);
      expect(changed.enabledCount, 4);
      expect(changed.toJson().keys.toSet(), {
        'game_reminders',
        'clan_callups',
        'party_invites',
        'ladder_moves',
        'replays_ready',
        'news_and_offers',
      });
      expect(
        YouNotificationPreferences.fromJson(changed.toJson()).toJson(),
        changed.toJson(),
      );
      expect(
        () => YouNotificationPreferences.fromJson({'game_reminders': true}),
        throwsFormatException,
      );
    },
  );

  test('wallet preserves fractional cents and keeps BHD separate', () {
    final wallet = YouWallet.fromJson(walletJson);
    expect(wallet.label, r'$6.505');
    expect(wallet.otherBalances.single.label, '1.234 BHD');
    expect(() => wallet.balances.clear(), throwsUnsupportedError);
    expect(
      YouWallet.fromJson({...walletJson, 'balance_fils': 13000}).label,
      r'$13.00',
    );
    expect(
      () => YouWallet.fromJson({...walletJson, 'balance_fils': null}),
      throwsFormatException,
    );
  });

  test(
    'repository sends exact preferences to existing RPCs and reads wallet',
    () async {
      final requests = <http.Request>[];
      const chosen = YouNotificationPreferences(gameReminders: false);
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          final body = request.url.path.endsWith('get_my_fieldrush_wallet')
              ? walletJson
              : {'notifications': chosen.toJson()};
          return http.Response(
            jsonEncode(body),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = SupabaseYouSettingsRepository(client: client);
      expect((await repository.loadNotifications()).gameReminders, isFalse);
      expect((await repository.saveNotifications(chosen)).enabledCount, 3);
      expect((await repository.loadWallet()).label, r'$6.505');
      expect(requests.map((request) => request.url.path).toList(), [
        '/rest/v1/rpc/get_my_profile_settings',
        '/rest/v1/rpc/update_my_notification_preferences',
        '/rest/v1/rpc/get_my_fieldrush_wallet',
      ]);
      expect(jsonDecode(requests[1].body), {
        'preferences_to_use': chosen.toJson(),
      });
    },
  );

  Future<void> show(
    WidgetTester tester,
    Widget widget, {
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: widget,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'failed preference save retains confirmed values and retry persists',
    (tester) async {
      final repository = _Repository(walletJson)..failSave = true;
      await show(tester, YouNotificationsScreen(repository: repository));
      final toggle = find.byKey(const Key('you-notification-game_reminders'));
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.text('4 on'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.text('4 on'), findsOneWidget);
      expect(
        find.textContaining('Could not save this change.'),
        findsOneWidget,
      );
      expect(repository.preferences.gameReminders, isTrue);
      repository.failSave = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.text('3 on'), findsOneWidget);
      expect(repository.preferences.gameReminders, isFalse);
      expect(find.textContaining('Could not save this change.'), findsNothing);
    },
  );

  testWidgets(
    'pending save disables other toggles until response is confirmed',
    (tester) async {
      final repository = _Repository(walletJson);
      await show(tester, YouNotificationsScreen(repository: repository));
      final completion = Completer<YouNotificationPreferences>();
      repository.saveCompletion = completion;
      await tester.tap(
        find.byKey(const Key('you-notification-game_reminders')),
      );
      await tester.pump();
      expect(repository.saveCalls, 1);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('you-notification-party_invites')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('you-notification-game_reminders')),
            )
            .value,
        isTrue,
      );
      completion.complete(
        repository.preferences.copyWith(gameReminders: false),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('you-notification-party_invites')),
            )
            .onChanged,
        isNotNull,
      );
      expect(find.text('3 on'), findsOneWidget);
    },
  );

  testWidgets(
    'preference load error has retry and no invented active toggles',
    (tester) async {
      final repository = _Repository(walletJson)..failLoad = true;
      await show(tester, YouNotificationsScreen(repository: repository));
      expect(find.byType(Switch), findsNothing);
      expect(find.text('4 on'), findsNothing);
      repository.failLoad = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNWidgets(6));
      expect(find.text('4 on'), findsOneWidget);
    },
  );

  testWidgets(
    'wallet shows exact real currency balances without top-up controls',
    (tester) async {
      await show(
        tester,
        YouWalletScreen(repository: _Repository(walletJson)),
        textScale: 1.4,
      );
      expect(find.text(r'$6.505'), findsOneWidget);
      expect(find.text('1.234 BHD'), findsOneWidget);
      expect(find.text('Add money'), findsNothing);
      expect(find.text('Activity'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wallet load failure does not show a zero balance and can retry',
    (tester) async {
      final repository = _Repository(walletJson)..failWallet = true;
      await show(tester, YouWalletScreen(repository: repository));
      expect(find.text(r'$0.00'), findsNothing);
      expect(
        find.textContaining('Could not load your wallet balance.'),
        findsOneWidget,
      );
      repository.failWallet = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(r'$6.505'), findsOneWidget);
    },
  );

  testWidgets(
    'payment screen describes checkout availability without pretend saved cards',
    (tester) async {
      await show(tester, const YouPaymentMethodsScreen(), textScale: 1.4);
      expect(find.text('Visa & Mastercard'), findsOneWidget);
      expect(find.text('Apple Pay'), findsOneWidget);
      expect(
        find.textContaining('when supported on your device'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('4242'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Repository implements YouSettingsRepository {
  _Repository(this.walletJson);
  final Map<String, dynamic> walletJson;
  YouNotificationPreferences preferences = const YouNotificationPreferences();
  bool failSave = false;
  bool failLoad = false;
  bool failWallet = false;
  int saveCalls = 0;
  Completer<YouNotificationPreferences>? saveCompletion;

  @override
  Future<YouNotificationPreferences> loadNotifications() async {
    if (failLoad) throw StateError('Network unavailable');
    return preferences;
  }

  @override
  Future<YouNotificationPreferences> saveNotifications(
    YouNotificationPreferences next,
  ) async {
    saveCalls++;
    if (failSave) throw StateError('Network unavailable');
    if (saveCompletion != null) return saveCompletion!.future;
    preferences = next;
    return preferences;
  }

  @override
  Future<YouWallet> loadWallet() async {
    if (failWallet) throw StateError('Network unavailable');
    return YouWallet.fromJson(walletJson);
  }
}
