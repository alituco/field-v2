import 'dart:math';

import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/moderation/account_restriction_screen.dart';
import 'package:field/src/moderation/moderation.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/profile/profile_screen.dart';
import 'package:field/src/support/contact_support_sheet.dart';
import 'package:field/src/support/support.dart';
import 'package:field/src/support/support_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('support RPC payload only contains the public submission contract', () {
    const draft = SupportRequestDraft(
      category: SupportRequestCategory.bookingOrPayment,
      details: '  My refund has not appeared yet.  ',
      clientRequestId: '11111111-1111-4111-8111-111111111111',
      context: {'entry_point': 'profile'},
    );

    expect(draft.toRpcParams(), {
      'category_to_use': 'BOOKING_OR_PAYMENT',
      'details_to_use': 'My refund has not appeared yet.',
      'context_to_use': {'entry_point': 'profile'},
      'client_request_id_to_use': '11111111-1111-4111-8111-111111111111',
    });
    expect(
      SupportRequestReceipt.fromRpcResponse({
        'ticket_id': 'f5033f51-2046-4d08-9695-78b317da403c',
        'reference': 'fld-0042',
      }).shortReference,
      'FLD-0042',
    );
  });

  test('support retry keys are valid UUID v4 values', () {
    final requestId = createSupportClientRequestId(random: _FixedRandom());

    expect(
      requestId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
          r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  testWidgets('current profile can send a validated support request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final supportRepository = _FakeSupportRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepository: _FakeProfileRepository(),
            supportRepository: supportRepository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-content')), findsOneWidget);
    final supportAction = find.byKey(const ValueKey('profile-support-action'));
    await tester.scrollUntilVisible(
      supportAction,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Help & support'), findsOneWidget);
    await tester.tap(supportAction);
    await tester.pumpAndSettle();

    expect(find.byKey(contactSupportSheetKey), findsOneWidget);
    expect(
      Theme.of(
        tester.element(find.byKey(contactSupportSheetKey)),
      ).textTheme.bodyMedium?.fontFamily,
      'PlusJakartaSans',
    );
    expect(
      tester.widget<Text>(find.text('How can we help?')).style?.fontFamily,
      'Outfit',
    );
    final surface = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(contactSupportSheetKey),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (surface.decoration! as BoxDecoration).color,
      FieldrushAuthTheme.cream,
    );
    final submit = find.byKey(const ValueKey('support-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('support-category-booking_or_payment')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('support-details')),
      'Too short',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('support-details')),
      'My refund has not appeared after I cancelled the booking.',
    );
    tester.testTextInput.hide();
    await tester.pump();
    await tester.ensureVisible(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(supportRepository.requests, hasLength(1));
    expect(
      supportRepository.requests.single.category,
      SupportRequestCategory.bookingOrPayment,
    );
    expect(supportRepository.requests.single.context, {
      'entry_point': 'profile',
    });
    expect(find.byKey(contactSupportSheetKey), findsNothing);
    expect(find.text('Request sent · reference FLD-0042'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewing another player does not show the account support row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepository: _FakeProfileRepository(),
            profileId: 'other-player',
            supportRepository: _FakeSupportRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-support-action')), findsNothing);
  });

  testWidgets('restricted account support sends status context', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final supportRepository = _FakeSupportRepository();
    final endsAt = DateTime(2026, 7, 20, 14, 30);
    await tester.pumpWidget(
      MaterialApp(
        home: RestrictedAccountScreen(
          status: ModerationStatus(
            state: ModerationState.suspended,
            scope: ModerationScope.account,
            message: 'Temporary safety suspension.',
            endsAt: endsAt,
            warningCount: 2,
          ),
          supportRepository: supportRepository,
          onSignOut: () async {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const Key('restricted-account-contact-support')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('restricted-account-support-sheet')),
      findsOneWidget,
    );

    final accountCategory = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('support-category-account_or_profile')),
    );
    expect(accountCategory.selected, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('support-details')),
      'I believe this account restriction was applied by mistake.',
    );
    tester.testTextInput.hide();
    await tester.pump();
    final submit = find.byKey(const ValueKey('support-submit'));
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    final request = supportRepository.requests.single;
    expect(request.category, SupportRequestCategory.accountOrProfile);
    expect(request.context['entry_point'], 'restricted_account');
    expect(request.context['moderation_state'], 'SUSPENDED');
    expect(request.context['moderation_scope'], 'ACCOUNT');
    expect(
      request.context['moderation_message'],
      'Temporary safety suspension.',
    );
    expect(request.context['warning_count'], 2);
    expect(
      request.context['moderation_ends_at'],
      endsAt.toUtc().toIso8601String(),
    );
    expect(find.text('Request sent · reference FLD-0042'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FixedRandom implements Random {
  var _next = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    final value = _next % max;
    _next += 17;
    return value;
  }
}

class _FakeSupportRepository implements SupportRepository {
  final List<SupportRequestDraft> requests = [];

  @override
  Future<SupportRequestReceipt> submitRequest(
    SupportRequestDraft request,
  ) async {
    requests.add(request);
    return const SupportRequestReceipt(
      id: 'f5033f51-2046-4d08-9695-78b317da403c',
      reference: 'FLD-0042',
    );
  }
}

class _FakeProfileRepository implements ProfileRepository {
  static const profile = PlayerProfile(
    id: 'current-player',
    displayName: 'Dana Alawi',
    username: 'bh_dana_08',
    bio: '',
    followingCount: 0,
    fansCount: 0,
    appearances: 0,
    goals: 0,
    assists: 0,
    highlights: [],
    career: [],
  );

  @override
  String? get currentUserId => profile.id;

  @override
  Future<PlayerProfile> getCurrentProfile() async => profile;

  @override
  Future<PlayerProfile> getProfile(String profileId) async {
    return PlayerProfile(
      id: profileId,
      displayName: 'Noor Saleh',
      username: 'noor',
      bio: '',
      followingCount: 0,
      fansCount: 0,
      appearances: 0,
      goals: 0,
      assists: 0,
      highlights: const [],
      career: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
