import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'checkout_load_delivery.dart';

enum CheckoutLoadOutcome {
  started('started'),
  ready('ready'),
  failed('failed'),
  timedOut('timed_out'),
  closed('closed');

  const CheckoutLoadOutcome(this.value);
  final String value;
}

typedef CheckoutLoadEventWriter =
    Future<void> Function({
      required String attemptId,
      required CheckoutLoadOutcome outcome,
      required int elapsedMs,
      String? reason,
    });

/// One attempt measures the initial load of one native payment selector.
class CheckoutLoadAttempt {
  CheckoutLoadAttempt({CheckoutLoadEventWriter? writer}) : _writer = writer;

  final CheckoutLoadEventWriter? _writer;
  final _elapsed = Stopwatch();
  String? _attemptId;
  String? _accountId;

  void start() {
    if (_attemptId != null) return;
    _attemptId = const Uuid().v4();
    if (_writer == null) {
      _accountId = CheckoutLoadDelivery.instance.currentAccountId;
    }
    _elapsed.start();
    unawaited(_record(CheckoutLoadOutcome.started, 0));
  }

  void finish(CheckoutLoadOutcome outcome, {String? reason}) {
    if (!_elapsed.isRunning || outcome == CheckoutLoadOutcome.started) return;
    _elapsed.stop();
    unawaited(_record(outcome, _elapsed.elapsedMilliseconds, reason: reason));
  }

  Future<void> _record(
    CheckoutLoadOutcome outcome,
    int elapsedMs, {
    String? reason,
  }) async {
    try {
      final writer = _writer;
      if (writer != null) {
        await writer(
          attemptId: _attemptId!,
          outcome: outcome,
          elapsedMs: elapsedMs,
          reason: reason,
        );
        return;
      }
      final accountId = _accountId;
      if (accountId == null) return;
      await CheckoutLoadDelivery.instance.record(accountId, {
        'attempt_id_to_use': _attemptId!,
        'outcome_to_use': outcome.value,
        'elapsed_ms_to_use': elapsedMs.clamp(0, 0x7fffffff),
        'reason_to_use': reason,
        'platform_to_use': switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'ios',
          TargetPlatform.android => 'android',
          _ => 'other',
        },
        'app_version_to_use': const String.fromEnvironment(
          'APP_RELEASE_VERSION',
          defaultValue: 'unknown',
        ),
      });
    } catch (_) {
      // Recording a diagnostic must never interrupt checkout.
    }
  }
}
