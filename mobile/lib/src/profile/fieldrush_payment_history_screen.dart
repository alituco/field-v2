import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/read_timeout.dart';
import '../core/user_facing_error.dart';
import '../ui/field_loading.dart';
import 'player_history_repository.dart';

/// A secondary read: payment history never gates choosing a payment method.
class FieldrushPaymentHistorySection extends StatefulWidget {
  const FieldrushPaymentHistorySection({super.key, this.repository});

  final PlayerHistoryRepository? repository;

  @override
  State<FieldrushPaymentHistorySection> createState() =>
      _FieldrushPaymentHistorySectionState();
}

class _FieldrushPaymentHistorySectionState
    extends State<FieldrushPaymentHistorySection> {
  late PlayerHistoryRepository _repository;
  PlayerHistoryPage<PlayerPaymentHistoryEntry>? _page;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? SupabasePlayerHistoryRepository();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FieldrushPaymentHistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _repository = widget.repository ?? SupabasePlayerHistoryRepository();
      _page = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _repository
          .getPayments(limit: 3)
          .timeout(fieldReadTimeout);
      if (!mounted || generation != _generation) return;
      setState(() => _page = page);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userFacingError(
          error,
          fallback: 'Could not load payment history. Try again.',
        );
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openAll() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FieldrushPaymentHistoryScreen(
          repository: _repository,
          initialPage: _page,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _page?.items.take(3).toList() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 11),
          child: Text('PAYMENT HISTORY', style: _groupLabel),
        ),
        _HistoryCard(
          child: Column(
            children: [
              if (_loading && _page == null)
                const FieldLoadingContent(
                  label: 'Loading payment history',
                  rows: 3,
                  compact: true,
                )
              else if (entries.isEmpty && _error == null)
                const _HistoryMessage('Your payments will appear here.'),
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: _divider),
                _PaymentHistoryRow(entry: entries[i]),
              ],
              if (_error != null)
                _HistoryError(message: _error!, onRetry: _load),
              const Divider(height: 1, color: _divider),
              Material(
                color: const Color(0xFFFBFAF4),
                child: InkWell(
                  key: const ValueKey('see-all-payments'),
                  onTap: _openAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'See all payments',
                            style: _body(
                              12.5,
                              color: _ink,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: _muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class FieldrushPaymentHistoryScreen extends StatefulWidget {
  const FieldrushPaymentHistoryScreen({
    super.key,
    this.repository,
    this.initialPage,
  });

  final PlayerHistoryRepository? repository;
  final PlayerHistoryPage<PlayerPaymentHistoryEntry>? initialPage;

  @override
  State<FieldrushPaymentHistoryScreen> createState() =>
      _FieldrushPaymentHistoryScreenState();
}

class _FieldrushPaymentHistoryScreenState
    extends State<FieldrushPaymentHistoryScreen> {
  late PlayerHistoryRepository _repository;
  final _scroll = ScrollController();
  List<PlayerPaymentHistoryEntry> _entries = const [];
  PlayerHistoryCursor? _cursor;
  bool _loading = false;
  bool _failedReset = true;
  bool _loaded = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? SupabasePlayerHistoryRepository();
    _entries = widget.initialPage?.items ?? const [];
    _cursor = widget.initialPage?.nextCursor;
    _scroll.addListener(_maybeLoadMore);
    unawaited(_load(reset: true));
  }

  @override
  void didUpdateWidget(covariant FieldrushPaymentHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _generation++;
      _repository = widget.repository ?? SupabasePlayerHistoryRepository();
      _entries = const [];
      _cursor = null;
      _loaded = false;
      _loading = false;
      unawaited(_load(reset: true));
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter > 250 ||
        _loading ||
        !_loaded ||
        _error != null ||
        _cursor == null) {
      return;
    }
    unawaited(_load(reset: false));
  }

  Future<void> _load({required bool reset}) async {
    if (_loading || (!reset && _cursor == null)) return;
    final generation = ++_generation;
    final requestedCursor = reset ? null : _cursor;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _repository
          .getPayments(cursor: requestedCursor)
          .timeout(fieldReadTimeout);
      if (!mounted || generation != _generation) return;
      if (requestedCursor != null &&
          page.nextCursor?.id == requestedCursor.id &&
          page.nextCursor?.createdAt == requestedCursor.createdAt) {
        throw const FormatException('Payment history cursor did not advance.');
      }
      final combined =
          <String, PlayerPaymentHistoryEntry>{
            if (!reset)
              for (final entry in _entries) entry.id: entry,
            for (final entry in page.items) entry.id: entry,
          }.values.toList()..sort((a, b) {
            final time = b.paidAt.compareTo(a.paidAt);
            return time != 0 ? time : b.id.compareTo(a.id);
          });
      setState(() {
        _entries = combined;
        _cursor = page.nextCursor;
        _loaded = true;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failedReset = reset;
        _error = userFacingError(
          error,
          fallback: 'Could not load payment history. Try again.',
        );
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeLoadMore();
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<PlayerPaymentHistoryEntry>>{};
    for (final entry in _entries) {
      final date = entry.localPaidAt;
      final group = '${_months[date.month - 1]} ${date.year}';
      groups.putIfAbsent(group, () => []).add(entry);
    }
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        backgroundColor: _cream,
        body: SafeArea(
          child: FieldRefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 18, bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 36,
                        child: Material(
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: _border),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => Navigator.of(context).maybePop(),
                            child: const Tooltip(
                              message: 'Back',
                              child: Icon(
                                Icons.chevron_left_rounded,
                                size: 23,
                                color: _ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Payment history', style: _title)),
                    ],
                  ),
                ),
                if (_entries.isEmpty && _loading)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 0),
                    child: _HistoryCard(
                      child: FieldLoadingContent(
                        label: 'Loading payment history',
                        rows: 5,
                        compact: true,
                      ),
                    ),
                  ),
                if (_entries.isEmpty && !_loading && _error == null)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 0),
                    child: _HistoryCard(
                      child: _HistoryMessage('Your payments will appear here.'),
                    ),
                  ),
                for (final group in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 11),
                    child: Text(group.key, style: _groupLabel),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _HistoryCard(
                      child: Column(
                        children: [
                          for (var i = 0; i < group.value.length; i++) ...[
                            if (i > 0)
                              const Divider(height: 1, color: _divider),
                            _PaymentHistoryRow(entry: group.value[i]),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (_loading && _entries.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: FieldLoadingIndicator(label: 'Loading payments'),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _HistoryCard(
                      child: _HistoryError(
                        message: _error!,
                        onRetry: () => _load(reset: _failedReset),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaymentHistoryRow extends StatelessWidget {
  const _PaymentHistoryRow({required this.entry});

  final PlayerPaymentHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final date = entry.localGameStartsAt;
    final kind = entry.purpose == 'SOLO_BOOKING'
        ? 'Solo game'
        : entry.purpose.startsWith('CLAN_')
        ? 'Clan game'
        : 'Payment';
    final title = date == null
        ? kind
        : '$kind · ${_weekdays[date.weekday - 1]}, ${_shortMonths[date.month - 1]} ${date.day}';
    final destination = entry.refundDestinationLabel;
    final String subtitle;
    final String? badge;
    final Color badgeColor;
    if (entry.isFullyRefunded) {
      subtitle = entry.gameCancelled
          ? 'Cancelled · back to $destination'
          : 'Refunded to $destination';
      badge = 'REFUNDED';
      badgeColor = _forest;
    } else if (entry.refundNeedsReview || entry.hasFailedRefund) {
      subtitle = entry.isPartiallyRefunded
          ? '${entry.refundAmountLabel} refunded · review needed'
          : 'Refund needs review · $destination';
      badge = 'REFUND NEEDS REVIEW';
      badgeColor = FieldrushAuthTheme.danger;
    } else if (entry.hasPendingRefund) {
      subtitle = entry.isPartiallyRefunded
          ? '${entry.refundAmountLabel} refunded · more pending'
          : 'Refund pending · $destination';
      badge = 'REFUND PENDING';
      badgeColor = _muted;
    } else if (entry.isPartiallyRefunded) {
      subtitle = '${entry.refundAmountLabel} refunded to $destination';
      badge = 'PARTIALLY REFUNDED';
      badgeColor = _forest;
    } else {
      subtitle = entry.paymentMethodLabel;
      badge = null;
      badgeColor = _muted;
    }
    return Semantics(
      key: ValueKey('payment-history-${entry.id}'),
      label:
          '$title. $subtitle. ${entry.amountLabel}.${badge == null ? '' : ' $badge.'}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final largeText = MediaQuery.textScalerOf(context).scale(13) > 19;
              final stacked = largeText && constraints.maxWidth < 350;
              final description = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: stacked ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: _body(13, color: _ink, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    maxLines: stacked ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: _body(10.5),
                  ),
                ],
              );
              final amount = Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    entry.amountLabel,
                    key: ValueKey('payment-history-amount-${entry.id}'),
                    style:
                        const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 15,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ).copyWith(
                          color: entry.isFullyRefunded ? _refunded : _ink,
                          decoration: entry.isFullyRefunded
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      badge,
                      style: _body(
                        8.5,
                        color: badgeColor,
                        weight: FontWeight.w800,
                      ).copyWith(letterSpacing: .7),
                      textAlign: TextAlign.right,
                    ),
                  ],
                ],
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [description, const SizedBox(height: 10), amount],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: description),
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .48,
                    ),
                    child: amount,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: _border),
    ),
    child: child,
  );
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(message, style: _body(12)),
    ),
  );
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(liveRegion: true, child: Text(message, style: _body(12))),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

const _cream = Color(0xFFFAF7EF);
const _ink = Color(0xFF22301F);
const _forest = Color(0xFF386641);
const _muted = Color(0xFF55654A);
const _refunded = Color(0xFF8E897A);
const _border = Color(0xFFE6DFCB);
const _divider = Color(0xFFF0ECE0);
const _months = [
  'JANUARY',
  'FEBRUARY',
  'MARCH',
  'APRIL',
  'MAY',
  'JUNE',
  'JULY',
  'AUGUST',
  'SEPTEMBER',
  'OCTOBER',
  'NOVEMBER',
  'DECEMBER',
];
const _shortMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _title = TextStyle(
  fontFamily: 'Outfit',
  fontSize: 18,
  height: 1,
  fontWeight: FontWeight.w800,
  color: _ink,
  letterSpacing: -.2,
);
final _groupLabel = _body(
  11,
  weight: FontWeight.w800,
).copyWith(height: 1, letterSpacing: 1.5);
TextStyle _body(
  double size, {
  Color color = _muted,
  FontWeight weight = FontWeight.w600,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  height: 1.2,
  color: color,
  fontWeight: weight,
);
