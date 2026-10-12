/// The home shell keeps its tabs mounted. Brief tab switches reuse those
/// snapshots; explicit booking/profile changes still request an immediate
/// refresh through the existing activation ticks.
class TabRefreshPolicy {
  TabRefreshPolicy({
    this.tabCount = 5,
    this.freshFor = const Duration(seconds: 60),
    DateTime? now,
  }) : _lastRefresh = {
         for (var index = 0; index < tabCount; index++)
           index: now ?? DateTime.now(),
       };

  final int tabCount;
  final Duration freshFor;
  final Map<int, DateTime> _lastRefresh;

  bool activate(int index, {DateTime? now}) {
    RangeError.checkValueInInterval(index, 0, tabCount - 1, 'index');
    final time = now ?? DateTime.now();
    final last = _lastRefresh[index];
    if (last != null &&
        !time.isBefore(last) &&
        time.difference(last) < freshFor) {
      return false;
    }
    _lastRefresh[index] = time;
    return true;
  }

  void refreshed(int index, {DateTime? now}) {
    RangeError.checkValueInInterval(index, 0, tabCount - 1, 'index');
    _lastRefresh[index] = now ?? DateTime.now();
  }
}
