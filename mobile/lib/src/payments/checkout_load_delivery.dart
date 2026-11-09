import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A small local outbox for best-effort diagnostics. Storage operations are
/// serialized separately from network I/O so an offline RPC cannot hold up writes.
class CheckoutLoadDelivery {
  CheckoutLoadDelivery._();

  static final instance = CheckoutLoadDelivery._();

  @visibleForTesting
  CheckoutLoadDelivery.forTesting({
    required String project,
    required String? Function() account,
    required Future<void> Function(String account, Map<String, Object?> params)
    send,
    DateTime Function()? now,
  }) : _project = project,
       _account = account,
       _send = send,
       _now = now ?? DateTime.now;

  static const _lifetime = Duration(hours: 1);
  static const _capacity = 64;
  String? _project;
  String? Function()? _account;
  Future<void> Function(String account, Map<String, Object?> params)? _send;
  DateTime Function() _now = DateTime.now;
  Future<void> _storageTail = Future.value();
  Future<void>? _active;
  bool _requested = false;
  Timer? _retryTimer;

  String? get currentAccountId => _account?.call();

  void initialize(SupabaseClient client, String project) {
    if (_project != null) return;
    _project = project;
    _account = () => client.auth.currentSession?.user.id;
    _send = (account, params) async {
      final session = client.auth.currentSession;
      if (session == null || session.user.id != account || session.isExpired) {
        throw StateError('Original checkout session is unavailable.');
      }
      // Pin this request to the account checked above, even if a new account
      // signs in while Supabase's asynchronous HTTP middleware is running.
      await client
          .rpc('record_checkout_load_event', params: params)
          .setHeader('Authorization', 'Bearer ${session.accessToken}')
          .timeout(const Duration(seconds: 8));
    };
    client.auth.onAuthStateChange.listen(
      (_) => unawaited(retry()),
      onError: (Object _) {},
    );
    AppLifecycleListener(onResume: () => unawaited(retry()));
    unawaited(retry());
  }

  Future<void> record(String accountId, Map<String, Object?> params) async {
    if (_project == null) return;
    try {
      // Store only the diagnostic RPC's fields; never persist a session or an
      // entire checkout object in shared preferences.
      final event = <String, Object?>{
        for (final field in const [
          'attempt_id_to_use',
          'outcome_to_use',
          'platform_to_use',
          'app_version_to_use',
          'elapsed_ms_to_use',
          'reason_to_use',
        ])
          field: params[field],
      };
      final entry = _Entry(accountId, _now().millisecondsSinceEpoch, event);
      await _edit((rows) {
        if (rows.any(entry.matches)) return;
        rows.add(entry);
        if (rows.length > _capacity) rows.removeAt(0);
      });
      unawaited(retry());
    } catch (_) {
      // Local storage can be unavailable; checkout must still work.
    }
  }

  Future<void> retry() {
    if (_project == null) return Future.value();
    _requested = true;
    return _active ??= _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _requested = false;
        final account = currentAccountId;
        final pending = await _edit(
          (rows) => rows.where((e) => e.account == account).toList(),
        );
        for (final event in pending) {
          if (event.account != currentAccountId) break;
          if (_fresh(event)) {
            try {
              await _send!(event.account, event.params);
            } catch (error) {
              // A permanently invalid event must not block later diagnostics.
              if (error is! PostgrestException ||
                  !const {'22023', '22P02'}.contains(error.code)) {
                _retryLater();
                break;
              }
            }
          }
          await _edit((rows) => rows.removeWhere(event.matches));
        }
      } while (_requested);
    } catch (_) {
      _retryLater();
    } finally {
      _active = null;
    }
  }

  void _retryLater() {
    _retryTimer ??= Timer(const Duration(minutes: 1), () {
      _retryTimer = null;
      unawaited(retry());
    });
  }

  @visibleForTesting
  void cancelRetryTimer() => _retryTimer?.cancel();

  bool _fresh(_Entry e) {
    final age = _now().millisecondsSinceEpoch - e.queuedAt;
    return age >= 0 && age < _lifetime.inMilliseconds;
  }

  Future<T> _edit<T>(T Function(List<_Entry>) update) {
    final operation = _storageTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final key = 'checkout_load_queue_v1_$_project';
      final stored = prefs.getStringList(key) ?? const [];
      final rows = <_Entry>[];
      for (final line in stored) {
        try {
          final json = jsonDecode(line) as List;
          final entry = _Entry(
            json[0] as String,
            json[1] as int,
            Map<String, Object?>.from(json[2] as Map),
          );
          if (_fresh(entry)) rows.add(entry);
        } catch (_) {
          // A corrupt local entry should not block the remaining entries.
        }
      }
      final result = update(rows);
      final next = [
        for (final e in rows) jsonEncode([e.account, e.queuedAt, e.params]),
      ];
      if (!listEquals(next, stored)) {
        if (next.isEmpty) {
          await prefs.remove(key);
        } else {
          await prefs.setStringList(key, next);
        }
      }
      return result;
    });
    _storageTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

class _Entry {
  const _Entry(this.account, this.queuedAt, this.params);
  final String account;
  final int queuedAt;
  final Map<String, Object?> params;

  bool matches(_Entry e) =>
      account == e.account &&
      params['attempt_id_to_use'] == e.params['attempt_id_to_use'] &&
      params['outcome_to_use'] == e.params['outcome_to_use'];
}
