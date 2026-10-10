import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/fixture_detail_screen.dart';
import 'package:field/src/fixtures/fixture_repository.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reliability quote equality', () {
    test(
      'solo checkout detects policy or deposit changes when total is unchanged',
      () {
        final original = _soloCharge(
          policyVersionId: 'policy-1',
          matchFeeFils: 3000,
          totalFils: 3000,
        );

        expect(
          original.hasSameCheckoutTermsAs(
            _soloCharge(
              policyVersionId: 'policy-1',
              matchFeeFils: 3000,
              totalFils: 3000,
            ),
          ),
          isTrue,
        );
        expect(
          original.hasSameCheckoutTermsAs(
            _soloCharge(
              policyVersionId: 'policy-2',
              matchFeeFils: 3000,
              totalFils: 3000,
            ),
          ),
          isFalse,
        );
        expect(
          original.hasSameCheckoutTermsAs(
            _soloCharge(
              policyVersionId: 'policy-1',
              matchFeeFils: 2400,
              depositRequired: true,
              depositBps: 2500,
              depositFils: 600,
              totalFils: 3000,
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      'clan checkout detects policy or deposit changes when total is unchanged',
      () {
        final original = _clanCharge(
          policyVersionId: 'policy-1',
          baseAmountFils: 30000,
          totalFils: 30000,
        );

        expect(
          original.hasSameCheckoutTermsAs(
            _clanCharge(
              policyVersionId: 'policy-1',
              baseAmountFils: 30000,
              totalFils: 30000,
            ),
          ),
          isTrue,
        );
        expect(
          original.hasSameCheckoutTermsAs(
            _clanCharge(
              policyVersionId: 'policy-2',
              baseAmountFils: 30000,
              totalFils: 30000,
            ),
          ),
          isFalse,
        );
        expect(
          original.hasSameCheckoutTermsAs(
            _clanCharge(
              policyVersionId: 'policy-1',
              baseAmountFils: 24000,
              depositRequired: true,
              depositBps: 2500,
              depositFils: 6000,
              totalFils: 30000,
            ),
          ),
          isFalse,
        );
      },
    );

    test('solo cancellation detects non-price consequence changes', () {
      final original = _soloCancellation();

      expect(original.hasSameConsequencesAs(_soloCancellation()), isTrue);
      expect(
        original.hasSameConsequencesAs(
          _soloCancellation(policyVersionId: 'policy-2'),
        ),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(_soloCancellation(strikeDelta: 1)),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(
          _soloCancellation(depositForfeited: true),
        ),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(
          _soloCancellation(outcomeCode: 'CANCELLED_VERY_LATE'),
        ),
        isFalse,
      );
    });

    test('clan cancellation detects non-price consequence changes', () {
      final original = _clanCancellation();

      expect(original.hasSameConsequencesAs(_clanCancellation()), isTrue);
      expect(
        original.hasSameConsequencesAs(
          _clanCancellation(policyVersionId: 'policy-2'),
        ),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(
          _clanCancellation(depositForfeited: true),
        ),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(_clanCancellation(createsForfeit: true)),
        isFalse,
      );
      expect(
        original.hasSameConsequencesAs(
          _clanCancellation(opponentRefundAmountFils: 15000),
        ),
        isFalse,
      );
    });
  });

  testWidgets(
    'changed clan join terms require a second confirmation before joining',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = _openFixture();
      final repository = _ChangingClanChargeRepository(fixture);

      await tester.pumpWidget(
        MaterialApp(
          home: FixtureDetailScreen(
            fixture: fixture,
            fixtureRepository: repository,
            myClanMembership: const MyClanMembership(
              clan: _joiningClan,
              role: 'leader',
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Join Match'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Join for 30 BHD?'), findsOneWidget);

      await tester.tap(find.text('Pay 30 BHD'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.joinCalls, 0);
      expect(find.text('UPDATED CHECKOUT'), findsOneWidget);
      expect(find.text('Checkout changed · 30 BHD'), findsOneWidget);
      expect(find.textContaining('refundable 6 BHD'), findsOneWidget);

      await tester.tap(find.text('Pay 30 BHD'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.joinCalls, 1);
      expect(repository.previewCalls, 3);
      expect(find.text('Match joined. Game on.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

OpenQueueBookingCostPreview _soloCharge({
  required String policyVersionId,
  required int matchFeeFils,
  required int totalFils,
  bool depositRequired = false,
  int depositBps = 0,
  int depositFils = 0,
}) {
  return OpenQueueBookingCostPreview(
    currency: 'BHD',
    standardMatchFeeFils: 3000,
    replacementDiscountBps: matchFeeFils == 3000 ? 0 : 2000,
    discountAmountFils: 3000 - matchFeeFils,
    matchFeeFils: matchFeeFils,
    reliabilityDepositRequired: depositRequired,
    reliabilityDepositBps: depositBps,
    reliabilityDepositFils: depositFils,
    totalFils: totalFils,
    policyVersionId: policyVersionId,
  );
}

ClanFixtureChargePreview _clanCharge({
  required String policyVersionId,
  required int baseAmountFils,
  required int totalFils,
  bool depositRequired = false,
  int depositBps = 0,
  int depositFils = 0,
}) {
  return ClanFixtureChargePreview(
    currency: 'BHD',
    baseAmountFils: baseAmountFils,
    reliabilityDepositRequired: depositRequired,
    reliabilityDepositBps: depositBps,
    reliabilityDepositFils: depositFils,
    totalFils: totalFils,
    activeClanStrikes: 0,
    policyVersionId: policyVersionId,
  );
}

OpenQueueCancellationPreview _soloCancellation({
  String policyVersionId = 'policy-1',
  String outcomeCode = 'CANCELLED_LATE',
  int strikeDelta = 0,
  bool depositForfeited = false,
}) {
  return OpenQueueCancellationPreview(
    canCancel: true,
    refundPercent: 50,
    refundAmountFils: 1500,
    refundCutoffAt: DateTime.utc(2026, 7, 20),
    policyVersionId: policyVersionId,
    outcomeCode: outcomeCode,
    strikeDelta: strikeDelta,
    refundBps: 5000,
    refundDestination: 'FIELD_WALLET',
    depositForfeited: depositForfeited,
    explanation: 'Policy-defined cancellation outcome.',
  );
}

ClanFixtureCancellationPreview _clanCancellation({
  String policyVersionId = 'policy-1',
  bool depositForfeited = false,
  bool createsForfeit = false,
  int opponentRefundAmountFils = 0,
}) {
  return ClanFixtureCancellationPreview(
    canCancel: true,
    outcomeCode: 'CLAN_EARLY_CANCELLATION',
    cancellationBand: 'EARLY',
    strikeDelta: 0,
    refundBps: 5000,
    refundAmountFils: 15000,
    depositForfeited: depositForfeited,
    opponentRefundAmountFils: opponentRefundAmountFils,
    createsForfeit: createsForfeit,
    forfeitScore: 3,
    currency: 'BHD',
    depositRefundFils: depositForfeited ? 0 : 3000,
    policyVersionId: policyVersionId,
  );
}

Fixture _openFixture() {
  return Fixture(
    id: 'fixture-quote-guard',
    status: FixtureStatus.open,
    homeClanId: _homeClan.id,
    venue: 'TFA, Saar',
    day: 'TUESDAY',
    timeSlot: FixtureTimeSlot.early.label,
    matchDate: DateTime.now().add(const Duration(days: 5)),
    createdBy: 'home-owner',
    homeClan: _homeClan,
  );
}

const _homeClan = FixtureClan(
  id: 'home',
  name: 'Mint Mavericks',
  tag: 'MMAV',
  emblem: '⚡',
  themeId: 'mint',
  patternId: 'solid',
  skillRating: 1500,
);

const _joiningClan = FixtureClan(
  id: 'joining',
  name: 'Riffa Raiders',
  tag: 'RIFR',
  emblem: '🏴',
  themeId: 'shadow',
  patternId: 'solid',
  skillRating: 1500,
);

class _ChangingClanChargeRepository
    implements
        FixtureRepository,
        FixtureReliabilityBookingRepository,
        FixtureBookingAvailabilityRepository {
  @override
  Future<bool> areClanGamesEnabled() async => true;
  _ChangingClanChargeRepository(this.fixture);

  Fixture fixture;
  int previewCalls = 0;
  int joinCalls = 0;

  ClanFixtureChargePreview get _initialQuote => _clanCharge(
    policyVersionId: 'policy-1',
    baseAmountFils: 30000,
    totalFils: 30000,
  );

  ClanFixtureChargePreview get _updatedQuote => _clanCharge(
    policyVersionId: 'policy-2',
    baseAmountFils: 24000,
    depositRequired: true,
    depositBps: 2500,
    depositFils: 6000,
    totalFils: 30000,
  );

  @override
  Future<Fixture> getFixture(String fixtureId) async => fixture;

  @override
  Future<ClanFixtureChargePreview> previewJoinFixtureCharge({
    required String fixtureId,
    required String clanId,
  }) async {
    previewCalls += 1;
    return previewCalls == 1 ? _initialQuote : _updatedQuote;
  }

  @override
  Future<Fixture> joinFixture({
    required String fixtureId,
    required String awayClanId,
  }) async {
    joinCalls += 1;
    fixture = Fixture(
      id: fixture.id,
      status: FixtureStatus.scheduled,
      homeClanId: fixture.homeClanId,
      awayClanId: _joiningClan.id,
      venue: fixture.venue,
      day: fixture.day,
      timeSlot: fixture.timeSlot,
      matchDate: fixture.matchDate,
      createdBy: fixture.createdBy,
      homeClan: fixture.homeClan,
      awayClan: _joiningClan,
    );
    return fixture;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
