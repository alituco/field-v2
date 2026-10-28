import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Supabase exposes this worker for injection; no real isolate is needed in a widget test.
// ignore: depend_on_referenced_packages
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'package:field/src/auth/fieldrush_account.dart';
import 'package:field/src/clans/clan_repository.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/leaderboard/leaderboard.dart';
import 'package:field/src/leaderboard/leaderboard_repository.dart';
import 'package:field/src/open_queue/open_queue_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/open_queue/fieldrush_game_detail_screen.dart';
import 'package:field/src/open_queue/fieldrush_booking_flow.dart';
import 'package:field/src/profile/fieldrush_match_history_screen.dart';
import 'package:field/src/profile/fieldrush_cancelled_game_screen.dart';
import 'package:field/src/profile/fieldrush_payment_history_screen.dart';
import 'package:field/src/profile/player_history_repository.dart';
import 'package:field/src/profile/fieldrush_you_screen.dart';
import 'package:field/src/profile/fieldrush_you_settings.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_connections_screen.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/reliability/reliability.dart';
import 'package:field/src/referrals/referrals.dart';
import 'package:field/src/referrals/referral_repository.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Payment methods opens the signed-in player payment history', (
    tester,
  ) async {
    final history = _BookingHistory();
    await tester.pumpWidget(_app(history: history));
    await tester.pumpAndSettle();
    final paymentMethods = find.byKey(const Key('you-payment-methods'));
    await tester.ensureVisible(paymentMethods);
    await tester.pumpAndSettle();
    await tester.tap(paymentMethods);
    await tester.pumpAndSettle();
    expect(find.byType(YouPaymentMethodsScreen), findsOneWidget);
    expect(find.byKey(const Key('payment-history-charge')), findsOneWidget);
    expect(history.paymentReads, 1);
    expect(history.cancelledReads, 0);
    await tester.ensureVisible(find.byKey(const Key('see-all-payments')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('see-all-payments')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushPaymentHistoryScreen), findsOneWidget);
    expect(find.text(r'$8.00'), findsOneWidget);
  });

  testWidgets('cancelled receipt Find another game opens the booking flow', (
    tester,
  ) async {
    final history = _BookingHistory();
    await tester.pumpWidget(_app(history: history));
    await tester.pumpAndSettle();
    final matchHistory = find.byKey(const Key('you-match-history'));
    await tester.ensureVisible(matchHistory);
    await tester.tap(matchHistory);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('you-cancelled-history-cancelled')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushCancelledGameScreen), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('cancelled-game-find-another')),
    );
    await tester.tap(find.byKey(const Key('cancelled-game-find-another')));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushBookingFlow), findsOneWidget);
    expect(find.byType(FieldrushCancelledGameScreen), findsNothing);
    expect(find.byType(FieldrushMatchHistoryScreen), findsNothing);
    expect(find.text('Try again'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('booking-see-games')));
    await tester.pumpAndSettle();
    expect(
      find.text('No upcoming games are open yet. Check back soon.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'referral timeout never hides profile and retry restores the card',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = Completer<ReferralSummary>();
      final referrals = _PendingReferrals()..pending = pending;
      await tester.pumpWidget(_app(referrals: referrals));
      await tester.pump();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Could not refresh referrals.'), findsOneWidget);
      expect(find.text('Ali A.'), findsOneWidget);
      referrals.pending = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('ALI'), findsOneWidget);
      expect(find.text('Have a referral code?'), findsOneWidget);
      pending.complete(_referralSummary('OLD'));
      await tester.pump();
      expect(find.text('OLD'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'optional wallet timeout keeps profile and rating, then retries without losing cached balance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = Completer<YouWallet>();
      final settings = _PendingSettings()..pendingWallet = pending;
      final profiles = _Profiles();
      final ratings = _Ratings();
      await tester.pumpWidget(
        _app(profiles: profiles, ratings: ratings, settings: settings),
      );
      await tester.pump();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(find.byKey(const ValueKey('you-loading')), findsNothing);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Could not refresh wallet.'), findsOneWidget);
      expect(find.text(r'$13.00'), findsNothing);
      settings.pendingWallet = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(r'$13.00'), findsOneWidget);
      final refresh = Completer<YouWallet>();
      settings.pendingWallet = refresh;
      await tester.pumpWidget(
        _app(
          profiles: profiles,
          ratings: ratings,
          settings: settings,
          activationTick: 1,
        ),
      );
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text(r'$13.00'), findsOneWidget);
      expect(find.text('Could not refresh wallet.'), findsOneWidget);
      pending.complete(
        YouWallet(
          primaryBalance: const FieldWalletBalance(
            currency: 'USD',
            balanceFils: 99000,
          ),
          balances: const [],
        ),
      );
      await tester.pump();
      expect(find.text(r'$99.00'), findsNothing);
    },
  );

  testWidgets(
    'real repository summary shows identity and SR while profile extras stall',
    (tester) async {
      final pending = Completer<http.Response>();
      final requests = <String>[];
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key',
        isolate: _ImmediateJsonWorker(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/rest/v1/profiles') {
            return http.Response(
              jsonEncode({
                'id': 'viewer',
                'display_name': 'Viewer Name',
                'username': 'viewer',
                'bio': '',
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return pending.future;
        }),
      );
      addTearDown(() => tester.runAsync(client.dispose));
      await tester.runAsync(
        () => client.auth.recoverSession(jsonEncode(_testSession('viewer'))),
      );
      await tester.pumpWidget(
        _app(profiles: SupabaseProfileRepository(client: client)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Viewer Name'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(find.text('Loading match history and clips…'), findsOneWidget);
      expect(requests.any((path) => path != '/rest/v1/profiles'), isTrue);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('Viewer Name'), findsOneWidget);
      expect(
        find.text('Match history and clips unavailable. Retry to load them.'),
        findsOneWidget,
      );
      expect(find.text('Could not refresh profile details.'), findsOneWidget);
      expect(
        find.text('Open the replay of a finished match and tap Clip.'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      pending.complete(
        http.Response('[]', 200, headers: {'content-type': 'application/json'}),
      );
      await tester.pump();
    },
  );

  testWidgets(
    'an account change discards late profile and wallet responses from the previous player',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final profiles = _ChangingUserProfiles();
      final oldWallet = Completer<YouWallet>();
      final settings = _PendingSettings()..pendingWallet = oldWallet;
      final ratings = _Ratings();
      await tester.pumpWidget(
        _app(profiles: profiles, ratings: ratings, settings: settings),
      );
      await tester.pump();
      profiles.userId = 'new';
      settings.pendingWallet = null;
      await tester.pumpWidget(
        _app(
          profiles: profiles,
          ratings: ratings,
          settings: settings,
          activationTick: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('New Player'), findsOneWidget);
      profiles.oldProfile.complete(_profile(name: 'Old Player'));
      oldWallet.complete(
        YouWallet(
          primaryBalance: const FieldWalletBalance(
            currency: 'USD',
            balanceFils: 99000,
          ),
          balances: const [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old Player'), findsNothing);
      expect(find.text('New Player'), findsOneWidget);
      expect(find.text(r'$13.00'), findsOneWidget);
      expect(find.text(r'$99.00'), findsNothing);
    },
  );

  testWidgets('You only offers email verification when delivery is enabled', (
    tester,
  ) async {
    final accounts = _EmailAccounts(enabled: false);
    await tester.pumpWidget(_app(accounts: accounts));
    await tester.pumpAndSettle();
    expect(find.text('VERIFY EMAIL'), findsNothing);
    accounts.enabled = true;
    await tester.pumpWidget(_app(accounts: accounts, activationTick: 1));
    await tester.pumpAndSettle();
    expect(find.text('VERIFY EMAIL'), findsOneWidget);
    accounts.verified = true;
    await tester.pumpWidget(_app(accounts: accounts, activationTick: 2));
    await tester.pumpAndSettle();
    expect(find.text('VERIFY EMAIL'), findsNothing);
  });

  testWidgets(
    'You clears the verify badge after returning from account settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final accounts = _EmailAccounts(enabled: true);
      await tester.pumpWidget(
        _app(accounts: accounts, onEdit: () async => accounts.verified = true),
      );
      await tester.pumpAndSettle();
      expect(find.text('VERIFY EMAIL'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('you-account-details')));
      await tester.pumpAndSettle();
      expect(find.text('VERIFY EMAIL'), findsNothing);
    },
  );

  testWidgets('sign-out sheet is themed, cancellable and confirms only once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var signOutCalls = 0;
    await tester.pumpWidget(_app(onSignOut: () async => signOutCalls++));
    await tester.pumpAndSettle();
    final signOut = find.byKey(const ValueKey('you-sign-out'));
    await tester.scrollUntilVisible(
      signOut,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(signOut);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fieldrush-sign-out-cancel')));
    await tester.pumpAndSettle();
    expect(signOutCalls, 0);
    expect(find.byType(FieldrushModal), findsNothing);
    await tester.tap(signOut);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fieldrush-sign-out-confirm')));
    await tester.pumpAndSettle();
    expect(signOutCalls, 1);
    expect(find.byType(FieldrushModal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first You load shows a skeleton until profile and rating arrive',
    (tester) async {
      final response = Completer<PlayerProfile>();
      await tester.pumpWidget(_app(profiles: _Profiles(first: response)));
      await tester.pump();
      expect(find.text('You'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-loading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Rating unavailable'), findsNothing);

      response.complete(_profile(name: 'Ali A.'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('you-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(find.text('Ali A.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed first load leaves the skeleton for a usable retry', (
    tester,
  ) async {
    final response = Completer<PlayerProfile>();
    await tester.pumpWidget(_app(profiles: _Profiles(first: response)));
    await tester.pump();
    response.completeError(StateError('Unavailable'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
    expect(find.text('Could not load your profile'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Ali A.'), findsOneWidget);
    expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reactivating You keeps its loaded rank during background refresh',
    (tester) async {
      final response = Completer<PlayerRatingLeaderboardEntry>();
      final profiles = _Profiles();
      final ratings = _Ratings(refresh: response);
      await tester.pumpWidget(_app(profiles: profiles, ratings: ratings));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);

      await tester.pumpWidget(
        _app(profiles: profiles, ratings: ratings, activationTick: 1),
      );
      await tester.pump();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('you-rating-unavailable')),
        findsNothing,
      );

      response.complete(
        await _Ratings().loadCurrentPlayerRating(activeLeaderboardSeason),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('you-rating-loading')), findsNothing);
      expect(find.byKey(const ValueKey('you-rating-ranked')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('You uses season stats and refreshes identity after Edit', (
    tester,
  ) async {
    final profiles = _Profiles();
    var editCount = 0;
    await tester.pumpWidget(
      _app(
        profiles: profiles,
        onEdit: () async {
          editCount++;
          profiles.name = 'Alex R.';
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ali A.'), findsOneWidget);
    expect(find.text('1700'), findsNothing);
    expect(find.text('2 played · 50% won'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('you-edit')));
    await tester.pumpAndSettle();
    expect(editCount, 1);
    expect(find.text('Alex R.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'optional section failures keep profile and account access working',
    (tester) async {
      var edits = 0;
      await tester.pumpWidget(
        _app(
          ratings: _Ratings(fail: true),
          settings: _Settings(fail: true),
          onEdit: () async {
            edits++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.text('Rating unavailable'), findsOneWidget);
      expect(find.text('1700'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('you-edit')));
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stale activation load cannot overwrite the latest profile', (
    tester,
  ) async {
    final first = Completer<PlayerProfile>();
    final profiles = _Profiles(first: first);
    await tester.pumpWidget(_app(profiles: profiles));
    await tester.pump();
    profiles.name = 'Latest P.';
    await tester.pumpWidget(_app(profiles: profiles, activationTick: 1));
    await tester.pumpAndSettle();
    expect(find.text('Latest P.'), findsOneWidget);
    first.complete(_profile(name: 'Outdated P.'));
    await tester.pumpAndSettle();
    expect(find.text('Latest P.'), findsOneWidget);
    expect(find.text('Outdated P.'), findsNothing);
  });

  testWidgets(
    'zero BHD wallet retains its currency when account and rating fail',
    (tester) async {
      await tester.pumpWidget(
        _app(
          ratings: _Ratings(fail: true),
          accounts: _UnavailableAccounts(),
          settings: _Settings(
            wallet: YouWallet(
              primaryBalance: const FieldWalletBalance(
                currency: 'BHD',
                balanceFils: 0,
              ),
              balances: const [
                FieldWalletBalance(currency: 'BHD', balanceFils: 0),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ali A.'), findsOneWidget);
      expect(find.text('Rating unavailable'), findsOneWidget);
      final walletRow = find.byKey(const ValueKey('you-wallet'));
      await tester.ensureVisible(walletRow);
      expect(
        find.descendant(of: walletRow, matching: find.text('0.000 BHD')),
        findsOneWidget,
      );
      expect(find.text(r'$0.00'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving match history discards an in-flight detail response', (
    tester,
  ) async {
    final response = Completer<OpenQueueMatchDetail>();
    final queue = _Queue(response: response);
    await tester.pumpWidget(
      _app(
        profiles: _Profiles(games: [_historyGame()]),
        queue: queue,
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-history-older-solo')));
    await tester.pump();
    expect(queue.requested, ['older-solo']);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchHistoryScreen), findsNothing);
    response.complete(_matchDetail());
    await tester.pumpAndSettle();
    expect(find.byType(FixtureDetailScreen), findsNothing);
    expect(find.byType(FieldrushGameDetailScreen), findsNothing);
    expect(find.byType(FieldrushYouScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stalled history match read times out and can be opened again', (
    tester,
  ) async {
    final pending = Completer<OpenQueueMatchDetail>();
    final queue = _Queue(response: pending, detail: _matchDetail());
    await tester.pumpWidget(
      _app(
        profiles: _Profiles(games: [_historyGame()]),
        queue: queue,
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    final game = find.byKey(const ValueKey('you-history-older-solo'));
    await tester.tap(game);
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchHistoryScreen), findsOneWidget);
    expect(find.byType(FieldrushGameDetailScreen), findsNothing);
    queue.response = null;
    await tester.tap(game);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    pending.complete(_matchDetail());
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushGameDetailScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('match history remains reachable during a rating outage', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        profiles: _Profiles(games: [_historyGame()]),
        ratings: _Ratings(fail: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rating unavailable'), findsOneWidget);
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushMatchHistoryScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('you-history-older-solo')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('solo history uses the current game UI and keeps player rating', (
    tester,
  ) async {
    final detail = _matchDetail();
    final profiles = _Profiles(games: [_historyGame()]);
    await tester.pumpWidget(
      _app(
        profiles: profiles,
        queue: _Queue(detail: detail),
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-history-older-solo')));
    await tester.pumpAndSettle();
    final screen = tester.widget<FieldrushGameDetailScreen>(
      find.byType(FieldrushGameDetailScreen),
    );
    expect(screen.gameId, 'older-solo');
    expect(screen.initialDetail, same(detail));
    expect(screen.playerRatingUpdate?.ratingBefore, 1188);
    expect(screen.playerRatingUpdate?.ratingChange, 11);
    expect(screen.playerRatingUpdate?.ratingAfter, 1199);
    expect(find.text('1188 → 1199'), findsOneWidget);
    expect(find.text('+11 SR'), findsOneWidget);
    expect(find.byType(FixtureDetailScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history keeps its frozen SR event in the current game screen', (
    tester,
  ) async {
    final profile = _Profiles(
      games: [_historyGame()],
      events: [
        ProfileRatingEvent(
          id: 'frozen-event',
          sourceType: 'OPEN_QUEUE',
          sourceId: 'older-solo',
          playedAt: DateTime.utc(2026, 9, 10, 3, 30),
          opponentLabel: 'Black',
          side: 'WHITE',
          result: 'WIN',
          ratingBefore: 1350,
          ratingChange: 23,
          ratingAfter: 1373,
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        profiles: profile,
        queue: _Queue(detail: _matchDetail()),
      ),
    );
    await tester.pumpAndSettle();
    final historyButton = find.byKey(const ValueKey('you-match-history'));
    await tester.ensureVisible(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-history-older-solo')));
    await tester.pumpAndSettle();
    expect(find.text('1350 → 1373'), findsOneWidget);
    expect(find.text('+23 SR'), findsOneWidget);
    expect(find.text('1188 → 1199'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fans route closes with counts and returns to You safely', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('you-fans')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileConnectionsScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('You'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'last five follows market season boundaries and actual played order',
    () {
      final profile = _profile(
        events: [
          _event('late', '2026-10-08T10:00:00Z'),
          _event('old-season', '2026-10-01T06:59:59Z'),
          _event('first', '2026-10-01T07:00:00Z'),
          _event('new-season', '2027-01-01T07:00:00Z'),
          _event('end', '2027-01-01T06:59:59Z'),
        ],
      );
      expect(
        fieldrushSeasonResults(
          profile,
          leaderboardSeasons[1],
          region: 'phoenix',
        ).map((e) => e.id),
        ['end', 'late', 'first'],
      );
    },
  );

  test('last five excludes archived results after a ranking reset', () {
    final profile = _profile(
      resetAt: DateTime.parse('2026-10-10T12:00:00Z'),
      events: [
        _event('archived', '2026-10-09T12:00:00Z'),
        _event('current', '2026-10-11T12:00:00Z'),
      ],
    );
    expect(
      fieldrushSeasonResults(
        profile,
        leaderboardSeasons[1],
      ).map((event) => event.id),
      ['current'],
    );
    expect(profile.playerRating!.events.length, 2);
  });

  testWidgets(
    'history opens the actual match and preserves player SR meaning',
    (tester) async {
      ProfilePreviousGame? opened;
      final game = ProfilePreviousGame(
        id: 'solo-real',
        type: ProfileGameType.solo,
        playedAt: DateTime(2026, 10, 9),
        venue: 'Phoenix',
        homeName: 'White',
        homeTag: 'WHITE',
        homeEmblem: '',
        awayName: 'Black',
        awayTag: 'BLACK',
        awayEmblem: '',
        homeScore: 2,
        awayScore: 3,
        playerSide: 'BLACK',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FieldrushMatchHistoryScreen(
            profile: _profile(
              games: [game],
              events: [
                _event('rated', '2026-10-09T10:00:00Z', gameId: game.id),
              ],
            ),
            onOpenGame: (game) async {
              opened = game;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 played · 1W 0D 0L'), findsOneWidget);
      expect(find.text('SR'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('you-history-solo-real')));
      await tester.pumpAndSettle();
      expect(identical(opened, game), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app({
  PlayerHistoryRepository? history,
  ReferralRepository? referrals,
  ProfileRepository? profiles,
  _Ratings? ratings,
  _Settings? settings,
  FieldrushAccountRepository? accounts,
  _Queue? queue,
  Future<void> Function()? onEdit,
  Future<void> Function()? onSignOut,
  int activationTick = 0,
}) => MaterialApp(
  home: Scaffold(
    body: FieldrushYouScreen(
      referralRepository: referrals,
      historyRepository: history,
      activationTick: activationTick,
      profileRepository: profiles ?? _Profiles(),
      leaderboardRepository: ratings ?? _Ratings(),
      settingsRepository: settings ?? _Settings(),
      accountRepository: accounts,
      clanRepository: _Clans(),
      fixtureRepository: _Fixtures(),
      openQueueRepository: queue ?? _Queue(),
      onOpenAccount: onEdit ?? () async {},
      onOpenRanks: () {},
      onSignOut: onSignOut ?? () async {},
    ),
  ),
);

class _BookingHistory implements PlayerHistoryRepository {
  int paymentReads = 0;
  int cancelledReads = 0;

  @override
  Future<PlayerHistoryPage<PlayerPaymentHistoryEntry>> getPayments({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) async {
    paymentReads++;
    return PlayerHistoryPage(
      items: [
        PlayerPaymentHistoryEntry(
          id: 'charge',
          paidAt: DateTime.utc(2026, 9, 1, 16),
          gameStartsAt: DateTime.utc(2026, 9, 2, 4),
          amountMinor: 800,
          paymentMethod: 'VISA',
          timezone: 'America/Phoenix',
        ),
      ],
    );
  }

  @override
  Future<PlayerHistoryPage<PlayerCancelledGame>> getCancelledGames({
    PlayerHistoryCursor? cursor,
    int limit = 30,
  }) async {
    cancelledReads++;
    return PlayerHistoryPage(
      items: [
        PlayerCancelledGame(
          gameId: 'cancelled',
          bookingId: 'booking',
          startsAt: DateTime.utc(2026, 9, 2, 4),
          endsAt: DateTime.utc(2026, 9, 2, 5),
          cancelledAt: DateTime.utc(2026, 9, 1, 16),
          venue: 'Reach 11 Fields',
          timezone: 'America/Phoenix',
          reason: 'The venue closed.',
          amountPaidMinor: 800,
          refundedMinor: 800,
          paymentMethod: 'VISA',
          ratingChange: 0,
          strikeChange: 0,
          streakKept: true,
        ),
      ],
    );
  }
}

ReferralSummary _referralSummary(String code) => ReferralSummary(
  serverNow: DateTime.utc(2026, 10, 24),
  entryExpiresAt: DateTime.utc(2026, 10, 31),
  canAddCode: true,
  ownCode: code,
  season: const ReferralSeason(id: 's1', label: 'S0', ended: false),
);

class _PendingReferrals implements ReferralRepository {
  Completer<ReferralSummary>? pending;
  @override
  String get currentUserId => 'me';
  @override
  Future<ReferralSummary> load() async =>
      pending?.future ?? _referralSummary('ALI');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profiles implements ProfileRepository {
  _Profiles({this.first, this.games = const [], this.events = const []});
  final Completer<PlayerProfile>? first;
  final List<ProfilePreviousGame> games;
  final List<ProfileRatingEvent> events;
  String name = 'Ali A.';
  int loads = 0;
  @override
  String get currentUserId => 'me';
  @override
  Future<PlayerProfile> getCurrentProfile() async {
    loads++;
    if (loads == 1 && first != null) return first!.future;
    return _profile(name: name, games: games, events: events);
  }

  @override
  Future<ProfileConnections> getConnections() async =>
      const ProfileConnections(following: [], fans: [], discover: []);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ratings implements LeaderboardRepository {
  _Ratings({this.fail = false, this.refresh});
  final bool fail;
  final Completer<PlayerRatingLeaderboardEntry>? refresh;
  int loads = 0;
  @override
  Future<PlayerRatingLeaderboardEntry> loadCurrentPlayerRating(
    LeaderboardSeason season,
  ) async {
    loads++;
    if (loads > 1 && refresh != null) return refresh!.future;
    if (fail) throw StateError('Unavailable');
    return const PlayerRatingLeaderboardEntry(
      rank: 38,
      profileId: 'me',
      displayName: 'Ali A.',
      username: 'ali',
      skillRating: 1199,
      matchesPlayed: 2,
      wins: 1,
      losses: 1,
      draws: 0,
      lastChange: -13,
      region: 'phoenix',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements YouSettingsRepository {
  _Settings({this.fail = false, this.wallet});
  final bool fail;
  final YouWallet? wallet;
  @override
  Future<YouNotificationPreferences> loadNotifications() async {
    if (fail) throw StateError('Unavailable');
    return const YouNotificationPreferences();
  }

  @override
  Future<YouWallet> loadWallet() async {
    if (fail) throw StateError('Unavailable');
    if (wallet != null) return wallet!;
    return YouWallet(
      primaryBalance: const FieldWalletBalance(
        currency: 'USD',
        balanceFils: 13000,
      ),
      balances: const [FieldWalletBalance(currency: 'USD', balanceFils: 13000)],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Clans implements ClanRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixtures implements FixtureRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Queue implements OpenQueueRepository {
  _Queue({this.response, this.detail});
  Completer<OpenQueueMatchDetail>? response;
  final OpenQueueMatchDetail? detail;
  final List<String> requested = [];

  @override
  Future<List<OpenQueueGame>> listGames() async => [];

  @override
  Future<List<OpenQueueBooking>> getMyUpcomingBookings() async => [];

  @override
  Future<OpenQueueMatchDetail> getMatchDetail(String gameId) async {
    requested.add(gameId);
    if (response != null) return response!.future;
    return detail!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnavailableAccounts implements FieldrushAccountRepository {
  @override
  Future<FieldrushAccount> loadAccount() async =>
      throw StateError('Unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmailAccounts extends Fake implements FieldrushAccountRepository {
  _EmailAccounts({required this.enabled});
  bool enabled;
  bool verified = false;

  @override
  bool get emailDeliveryEnabled => enabled;

  @override
  Future<FieldrushAccount> loadAccount() async => FieldrushAccount(
    draft: const AccountDraft(email: 'alex@example.com'),
    emailVerified: verified,
    completed: true,
    status: 'active',
  );
}

ProfilePreviousGame _historyGame() => ProfilePreviousGame(
  id: 'older-solo',
  type: ProfileGameType.solo,
  playedAt: DateTime.utc(2026, 9, 10, 3, 30),
  venue: 'Phoenix',
  homeName: 'White',
  homeTag: 'WHITE',
  homeEmblem: '',
  awayName: 'Black',
  awayTag: 'BLACK',
  awayEmblem: '',
  homeScore: 4,
  awayScore: 3,
  playerSide: 'WHITE',
);

OpenQueueMatchDetail _matchDetail() => OpenQueueMatchDetail(
  game: OpenQueueGame(
    id: 'older-solo',
    status: 'FINAL',
    venue: 'Phoenix',
    startsAt: DateTime.utc(2026, 9, 10, 3, 30),
    endsAt: DateTime.utc(2026, 9, 10, 4, 30),
    timezone: 'America/Phoenix',
    currency: 'USD',
    priceFils: 13000,
    ageLabel: '18+',
    capacity: 14,
    confirmedCount: 14,
    spots: const {},
    whiteScore: 4,
    blackScore: 3,
  ),
  scorers: const [],
  timeline: const [],
  players: const [
    OpenQueuePlayer(
      id: 'me',
      displayName: 'Ali A.',
      role: OpenQueueRole.attacker,
      team: 'WHITE',
      played: true,
      isMe: true,
      ratingAtMatchStart: 1188,
      ratingChange: 11,
    ),
  ],
);

PlayerProfile _profile({
  String name = 'Ali A.',
  DateTime? resetAt,
  List<ProfileRatingEvent> events = const [],
  List<ProfilePreviousGame> games = const [],
}) => PlayerProfile(
  id: 'me',
  displayName: name,
  username: 'ali',
  bio: '',
  followingCount: 2,
  fansCount: 3,
  appearances: 0,
  goals: 0,
  assists: 0,
  highlights: const [],
  career: const [],
  previousGames: games,
  playerRating: ProfilePlayerRating(
    ratingsResetAt: resetAt,
    skillRating: 1700,
    matchesPlayed: 100,
    wins: 70,
    losses: 20,
    draws: 10,
    lastChange: 30,
    region: 'phoenix',
    events: events,
  ),
);
ProfileRatingEvent _event(String id, String date, {String gameId = 'game'}) =>
    ProfileRatingEvent(
      id: id,
      sourceType: 'OPEN_QUEUE',
      sourceId: gameId,
      playedAt: DateTime.parse(date),
      opponentLabel: 'White',
      side: 'BLACK',
      result: 'WIN',
      ratingBefore: 1188,
      ratingChange: 11,
      ratingAfter: 1199,
    );

class _PendingSettings extends _Settings {
  Completer<YouWallet>? pendingWallet;
  @override
  Future<YouWallet> loadWallet() => pendingWallet?.future ?? super.loadWallet();
}

Map<String, dynamic> _testSession(String id) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': id, 'exp': expires})}.test',
    'refresh_token': 'test-refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}

class _ImmediateJsonWorker extends Fake implements YAJsonIsolate {
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
}

class _ChangingUserProfiles extends _Profiles {
  String userId = 'old';
  final oldProfile = Completer<PlayerProfile>();
  @override
  String get currentUserId => userId;
  @override
  Future<PlayerProfile> getCurrentProfile() => userId == 'old'
      ? oldProfile.future
      : Future.value(_profile(name: 'New Player'));
}
