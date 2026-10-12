import 'package:field/src/home/tab_refresh_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 12);

  test('quick switches reuse every initially mounted tab', () {
    final policy = TabRefreshPolicy(now: start);
    for (var index = 0; index < 5; index++) {
      expect(policy.activate(index, now: start), isFalse);
      expect(
        policy.activate(index, now: start.add(const Duration(seconds: 59))),
        isFalse,
      );
    }
  });

  test('stale tabs refresh once without refreshing other tabs', () {
    final policy = TabRefreshPolicy(now: start);
    final stale = start.add(const Duration(seconds: 60));
    expect(policy.activate(1, now: stale), isTrue);
    expect(policy.activate(1, now: stale), isFalse);
    expect(policy.activate(0, now: stale), isTrue);
  });

  test('explicit booking refresh renews the snapshot freshness', () {
    final policy = TabRefreshPolicy(now: start);
    policy.refreshed(1, now: start.add(const Duration(seconds: 50)));
    expect(
      policy.activate(1, now: start.add(const Duration(seconds: 60))),
      isFalse,
    );
    expect(
      policy.activate(1, now: start.add(const Duration(seconds: 110))),
      isTrue,
    );
  });

  test('a new account shell does not inherit another account cache', () {
    final first = TabRefreshPolicy(now: start);
    final second = TabRefreshPolicy(now: start.add(const Duration(minutes: 2)));
    expect(
      first.activate(4, now: start.add(const Duration(minutes: 2))),
      isTrue,
    );
    expect(
      second.activate(4, now: start.add(const Duration(minutes: 2))),
      isFalse,
    );
  });

  test('clock changes and invalid tabs fail safely', () {
    final policy = TabRefreshPolicy(now: start);
    expect(
      policy.activate(0, now: start.subtract(const Duration(seconds: 1))),
      isTrue,
    );
    expect(() => policy.activate(5), throwsRangeError);
    expect(() => policy.refreshed(-1), throwsRangeError);
  });
}
