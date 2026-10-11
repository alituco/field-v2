import 'package:field/src/fixtures/fixture.dart';
import 'package:field/src/fixtures/match_resolution.dart';
import 'package:field/src/open_queue/open_queue.dart';
import 'package:field/src/payments/refund_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'clan checkout uses server USD amounts, never a hardcoded BHD price',
    () {
      final quote = ClanFixtureChargePreview.fromJson({
        'currency': 'USD',
        'base_amount_fils': 80000,
        'reliability_deposit_fils': 16000,
        'total_fils': 96000,
      });
      expect(quote.baseAmountLabel, r'$80.00 USD');
      expect(quote.totalLabel, r'$96.00 USD');
      expect(quote.depositLabel, r'$16.00 USD');
    },
  );

  test('clan payment panel reads recorded currency and fee', () {
    final data = <String, dynamic>{
      'id': 'fixture',
      'home_clan_id': 'clan',
      'home_clan': {'id': 'clan', 'name': 'Clan'},
      'currency': 'USD',
      'base_price_fils': 80000,
    };
    expect(Fixture.fromJson(data).teamPriceLabel, r'$80.00 USD each');
    expect(
      Fixture.fromJson({
        ...data,
        'currency': 'BHD',
        'base_price_fils': 20000,
      }).teamPriceLabel,
      '20 BHD each',
    );
    expect(
      Fixture.fromJson({
        ...data,
        'currency': null,
        'base_price_fils': null,
      }).teamPriceLabel,
      'Price shown at checkout',
    );
  });

  test('Stripe cancellation quotes show original payment method and USD', () {
    final preview = OpenQueueCancellationPreview.fromJson({
      'can_cancel': true,
      'refund_bps': 10000,
      'refund_percent': 100,
      'refund_amount_fils': 13000,
      'currency': 'USD',
      'refund_destination': 'ORIGINAL_PAYMENT_METHOD',
    });
    expect(
      preview.refundDestinationLabel,
      '100% to your original payment method',
    );
    expect(preview.refundLabel, r'$13.00 to your original payment method');
  });

  test('historical wallet refund keeps its destination', () {
    final preview = OpenQueueCancellationPreview.fromJson({
      'refund_bps': 10000,
      'refund_amount_fils': 3000,
      'currency': 'BHD',
      'refund_destination': 'FIELD_WALLET',
    });
    expect(preview.refundLabel, '3 BHD to Field wallet');
  });

  for (final destination in ['ORIGINAL_PAYMENT_METHOD', 'stripe']) {
    test(
      '$destination cancellation narrative uses the authoritative destination',
      () {
        const explanation =
            'Cancellation outcome: Cancelled early. No reliability strike is added. '
            '100% of the match fee returns to your Field Wallet. '
            'The reliability deposit returns to your Field Wallet.';
        final preview = OpenQueueCancellationPreview.fromJson({
          'refund_destination': destination,
          'explanation': explanation,
        });
        expect(
          preview.displayExplanation,
          'Cancellation outcome: Cancelled early. No reliability strike is added. '
          '100% of the match fee returns to your original payment method. '
          'The reliability deposit returns to your original payment method.',
        );
        expect(preview.explanation, explanation);
      },
    );
  }

  for (final destination in ['FIELD_WALLET', null, 'OTHER']) {
    test('historical or unspecified $destination narrative is unchanged', () {
      const explanation =
          '50% of the match fee returns to your Field Wallet. '
          'The reliability deposit is forfeited.';
      final preview = OpenQueueCancellationPreview.fromJson({
        'refund_destination': destination,
        'explanation': explanation,
      });
      expect(preview.displayExplanation, explanation);
    });
  }

  test('current and absent Stripe explanations remain unchanged', () {
    const explanation = 'The refund returns to your original payment method.';
    for (final text in [explanation, null, '']) {
      final preview = OpenQueueCancellationPreview.fromJson({
        'refund_destination': 'ORIGINAL_PAYMENT_METHOD',
        'explanation': text,
      });
      expect(preview.displayExplanation, preview.explanation);
    }
  });

  test('clan cancellation requires acknowledgement if destination changes', () {
    final data = {
      'refund_amount_fils': 13000,
      'currency': 'USD',
      'refund_destination': 'ORIGINAL_PAYMENT_METHOD',
      'refund_status': 'PENDING',
    };
    final card = ClanFixtureCancellationPreview.fromJson(data);
    final wallet = ClanFixtureCancellationPreview.fromJson({
      ...data,
      'refund_destination': 'FIELD_WALLET',
    });
    expect(card.refundDestinationLabel, 'Original payment method');
    expect(card.refundStatus, 'PENDING');
    expect(card.hasSameConsequencesAs(wallet), isFalse);
  });

  test('queued refund does not claim money has already arrived', () {
    expect(
      cancellationRefundMessage(
        refundAmountFils: 13000,
        destination: 'ORIGINAL_PAYMENT_METHOD',
        status: 'PENDING',
      ),
      'Booking cancelled. Your refund to the original payment method is pending.',
    );
    expect(
      cancellationRefundMessage(
        refundAmountFils: 13000,
        destination: 'ORIGINAL_PAYMENT_METHOD',
        status: 'FAILED',
      ),
      contains('refund needs attention'),
    );
  });

  test(
    'completed refund distinguishes processor success from bank arrival',
    () {
      expect(
        cancellationRefundMessage(
          refundAmountFils: 13000,
          destination: 'ORIGINAL_PAYMENT_METHOD',
          status: 'SUCCEEDED',
        ),
        contains('Your bank may take a few days'),
      );
      expect(
        cancellationRefundMessage(refundAmountFils: 0),
        'Booking cancelled.',
      );
    },
  );

  test('resolution receipt shows USD and original destination', () {
    final refund = MatchResolutionRefund.fromJson({
      'amount_fils': 6500,
      'currency': 'USD',
      'destination': 'ORIGINAL_PAYMENT_METHOD',
      'status': 'PROCESSING',
    });
    expect(refund.amountLabel, r'$6.50');
    expect(refund.destinationLabel, 'Original payment method');
    expect(refund.statusLabel, 'Refund processing');
  });
}
