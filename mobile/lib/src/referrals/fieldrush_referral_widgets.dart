import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../home/fieldrush_home_widgets.dart';
import '../legal/fieldrush_policy_links.dart';
import 'referrals.dart';

const referralWash = Color(0xFFF2EFE3);
const referralLine = Color(0xFFF0ECE0);
const referralSecondaryInk = Color(0xFF3C4A38);
const referralPrizeWash = Color(0xFFF3EBD6);
const referralAmber = Color(0xFF8A6516);
const referralLight = Color(0xFFFBFAF4);

TextStyle referralText(
  double size, {
  Color color = FieldrushAuthTheme.muted,
  FontWeight weight = FontWeight.w600,
  double height = 1.4,
  double tracking = 0,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  fontWeight: weight,
  height: height,
  color: color,
  letterSpacing: tracking,
);

TextStyle referralOutfit(double size, {Color color = FieldrushAuthTheme.ink}) =>
    TextStyle(
      fontFamily: 'Outfit',
      fontSize: size,
      fontWeight: FontWeight.w800,
      height: 1.05,
      letterSpacing: -size * .01,
      color: color,
    );

String referralMoney(int minor) => minor % 100 == 0
    ? '\$${minor ~/ 100}'
    : '\$${(minor / 100).toStringAsFixed(2)}';

/// The You card, in the same position and proportions as the supplied HTML.
/// The deadline advances from server time rather than the device wall clock.
class FieldrushReferralCard extends StatefulWidget {
  const FieldrushReferralCard({
    super.key,
    required this.summary,
    required this.onShare,
    required this.onOpenLeaderboard,
    required this.onOpenCode,
  });

  final ReferralSummary summary;
  final VoidCallback onShare;
  final VoidCallback onOpenLeaderboard;
  final VoidCallback onOpenCode;

  @override
  State<FieldrushReferralCard> createState() => _FieldrushReferralCardState();
}

class _FieldrushReferralCardState extends State<FieldrushReferralCard> {
  final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _deadline;
  Timer? _refresh;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant FieldrushReferralCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.summary, oldWidget.summary)) {
      _elapsed.reset();
      _schedule();
    }
  }

  DateTime get _now => widget.summary.serverNow.add(_elapsed.elapsed);

  void _schedule() {
    _deadline?.cancel();
    _refresh?.cancel();
    final remaining = widget.summary.entryExpiresAt.difference(_now);
    _expired = remaining <= Duration.zero;
    if (!widget.summary.canAddCode || remaining <= Duration.zero) return;
    _deadline = Timer(remaining, () {
      if (!mounted) return;
      _refresh?.cancel();
      setState(() => _expired = true);
    });
    _refresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _refresh?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.summary;
    final friend = data.referrer;
    final canAdd =
        data.canAddCode && !_expired && data.entryExpiresAt.isAfter(_now);
    final needed = math.max(0, data.minimumReferrals - data.referralCount);
    final qualified = needed == 0;
    final countText =
        '${data.referralCount} '
        '${data.referralCount == 1 ? 'friend played' : 'friends played'}';
    final subline = data.season.ended
        ? qualified
              ? data.needsReview
                    ? 'Final place awaiting admin review'
                    : 'You finished #${data.rank ?? '–'} with ${data.referralCount} friends'
              : 'You needed ${data.minimumReferrals} friends to qualify'
        : !qualified
        ? '$needed more to make the leaderboard'
        : data.waitingCount > 0
        ? '${data.waitingCount} more joined, no game yet'
        : 'Top ${data.prizePlaces} win ${referralMoney(data.prizeEachMinor)} each';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ReferralSectionLabel('REFERRALS', top: 22),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
          child: ReferralSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!data.season.ended)
                  Container(
                    color: referralPrizeWash,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Text(
                          referralMoney(data.prizePoolMinor),
                          style: referralOutfit(24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'in Amazon gift cards. The top ${data.prizePlaces} '
                            'referrers get ${referralMoney(data.prizeEachMinor)} each.',
                            style: referralText(
                              11.5,
                              color: referralSecondaryInk,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: ReferralOfficialRulesNotice(),
                ),
                ReferralOwnCode(code: data.ownCode, onShare: widget.onShare),
                const Divider(height: 1, color: referralLine),
                _ReferralTap(
                  onTap: widget.onOpenLeaderboard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Text(
                        qualified && data.rank != null
                            ? '#${data.rank}'
                            : '${data.referralCount}',
                        style: referralOutfit(
                          24,
                          color: FieldrushAuthTheme.forest,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.season.ended
                                  ? 'Final standings are in'
                                  : countText,
                              style: referralText(
                                12.5,
                                color: FieldrushAuthTheme.ink,
                                weight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(subline, style: referralText(11, height: 1.3)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '›',
                        style: referralText(13.5, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: referralLine),
                if (friend != null)
                  _ReferralTap(
                    onTap: widget.onOpenCode,
                    color: referralLight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                    child: Row(
                      children: [
                        ReferralInitials(person: friend, size: 26, radius: 8),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'Referred by '),
                                TextSpan(
                                  text: friend.name,
                                  style: const TextStyle(
                                    color: FieldrushAuthTheme.ink,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            style: referralText(12.5, height: 1.3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const ReferralLinkedBadge(),
                      ],
                    ),
                  )
                else if (canAdd)
                  _ReferralTap(
                    onTap: widget.onOpenCode,
                    color: referralLight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final label = Text(
                          'Have a referral code?',
                          style: referralText(
                            12.5,
                            color: FieldrushAuthTheme.ink,
                            weight: FontWeight.w700,
                            height: 1.3,
                          ),
                        );
                        final days = ReferralDaysBadge(
                          expiresAt: data.entryExpiresAt,
                          now: _now,
                        );
                        final add = Text(
                          'Add ›',
                          style: referralText(
                            12,
                            color: FieldrushAuthTheme.forest,
                            weight: FontWeight.w800,
                            height: 1,
                          ),
                        );
                        if (constraints.maxWidth < 340 &&
                            MediaQuery.textScalerOf(context).scale(12) > 14) {
                          return Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 10,
                            runSpacing: 10,
                            children: [label, days, add],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: label),
                            const SizedBox(width: 10),
                            days,
                            const SizedBox(width: 10),
                            add,
                          ],
                        );
                      },
                    ),
                  )
                else
                  Container(
                    color: referralLight,
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Referral window closed',
                          style: referralText(
                            12.5,
                            color: FieldrushAuthTheme.ink,
                            weight: FontWeight.w800,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Referral codes can only be added during your 7-day referral window.',
                          style: referralText(11.5, height: 1.45),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ReferralSurface extends StatelessWidget {
  const ReferralSurface({super.key, required this.child, this.radius = 20});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: const BorderSide(color: FieldrushAuthTheme.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class ReferralSectionLabel extends StatelessWidget {
  const ReferralSectionLabel(
    this.label, {
    super.key,
    this.trailing,
    this.top = 22,
  });
  final String label;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, top, 20, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            label,
            style: referralText(11, weight: FontWeight.w800, tracking: 1.54),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing!),
          ),
        ],
      ],
    ),
  );
}

class ReferralOwnCode extends StatelessWidget {
  const ReferralOwnCode({super.key, required this.code, required this.onShare});
  final String code;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YOUR CODE',
                style: referralText(
                  9.5,
                  weight: FontWeight.w800,
                  tracking: 1.14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: referralOutfit(21).copyWith(letterSpacing: 1.26),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: onShare,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            backgroundColor: FieldrushAuthTheme.forest,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: referralText(
              12,
              color: Colors.white,
              weight: FontWeight.w800,
            ),
          ),
          icon: const Icon(Icons.ios_share_rounded, size: 14),
          label: const Text('Share'),
        ),
      ],
    ),
  );
}

class ReferralDaysBadge extends StatelessWidget {
  const ReferralDaysBadge({
    super.key,
    required this.expiresAt,
    required this.now,
  });
  final DateTime expiresAt;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final days = math.max(
      1,
      (expiresAt.difference(now).inSeconds / 86400).ceil(),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF7EED6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$days ${days == 1 ? 'DAY' : 'DAYS'} LEFT',
        style: referralText(
          9,
          color: referralAmber,
          weight: FontWeight.w800,
          tracking: .9,
          height: 1,
        ),
      ),
    );
  }
}

class ReferralLinkedBadge extends StatelessWidget {
  const ReferralLinkedBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: referralWash,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.lock_outline_rounded,
          size: 11,
          color: referralSecondaryInk,
        ),
        const SizedBox(width: 5),
        Text(
          'LINKED',
          style: referralText(
            9,
            color: referralSecondaryInk,
            weight: FontWeight.w800,
            tracking: .9,
            height: 1,
          ),
        ),
      ],
    ),
  );
}

class ReferralInitials extends StatelessWidget {
  const ReferralInitials({
    super.key,
    required this.person,
    this.size = 34,
    this.radius = 11,
    this.isMe = false,
    this.qualified = false,
    this.showDivision = false,
  });
  final ReferralPerson person;
  final double size;
  final double radius;
  final bool isMe;
  final bool qualified;
  final bool showDivision;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isMe
              ? qualified
                    ? FieldrushAuthTheme.forest
                    : const Color(0xFFDCE5D2)
              : referralWash,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Text(
          isMe ? 'YOU' : person.initials,
          style: referralOutfit(
            size >= 48
                ? 16
                : size <= 26
                ? 10
                : 12,
            color: isMe && qualified ? Colors.white : referralSecondaryInk,
          ),
        ),
      ),
      if (showDivision &&
          person.username.isNotEmpty &&
          person.ratingVisible &&
          person.division != null)
        Positioned(
          right: -9,
          bottom: -9,
          child: FieldrushDivisionShield(
            division: person.division!,
            size: 14,
            mini: true,
          ),
        ),
    ],
  );
}

class ReferralPersonCard extends StatelessWidget {
  const ReferralPersonCard({
    super.key,
    required this.person,
    required this.onTap,
    this.linked = false,
  });
  final ReferralPerson person;
  final VoidCallback? onTap;
  final bool linked;

  @override
  Widget build(BuildContext context) => ReferralSurface(
    radius: 18,
    child: _ReferralTap(
      onTap: person.username.isEmpty ? null : onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          ReferralInitials(person: person, size: 48, radius: 15),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(person.name, style: referralOutfit(16)),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (person.username.isNotEmpty)
                      Text(
                        '@${person.username}',
                        style: referralText(11.5, height: 1),
                      ),
                    if (person.username.isNotEmpty &&
                        person.ratingVisible &&
                        person.division != null) ...[
                      Text('·', style: referralText(11.5, height: 1)),
                      FieldrushDivisionShield(
                        division: person.division!,
                        size: 14,
                        mini: true,
                      ),
                      Text(
                        'Division ${person.division}',
                        style: referralText(11.5, height: 1),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (linked) ...[
            const SizedBox(width: 8),
            const ReferralLinkedBadge(),
          ],
        ],
      ),
    ),
  );
}

class ReferralOfficialRulesNotice extends StatelessWidget {
  const ReferralOfficialRulesNotice({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Apple is not a sponsor of, and is not involved in, this promotion.',
        style: referralText(11.5, height: 1.45),
      ),
      TextButton(
        onPressed: () => openFieldrushReferralRules(context),
        style: TextButton.styleFrom(
          foregroundColor: FieldrushAuthTheme.forest,
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 44),
          alignment: Alignment.centerLeft,
          textStyle: referralText(12, weight: FontWeight.w800),
        ),
        child: const Text('Official rules'),
      ),
    ],
  );
}

class ReferralPrizeBanner extends StatelessWidget {
  const ReferralPrizeBanner({super.key, required this.summary});
  final ReferralSummary summary;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
    decoration: BoxDecoration(
      color: referralPrizeWash,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${summary.season.displayLabel.toUpperCase()} REFERRALS',
                style: referralText(
                  10,
                  weight: FontWeight.w800,
                  tracking: 1.4,
                  height: 1,
                ),
              ),
            ),
            const Icon(
              Icons.card_giftcard_outlined,
              size: 20,
              color: FieldrushAuthTheme.ink,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          referralMoney(summary.prizePoolMinor),
          style: referralOutfit(44).copyWith(height: .9, letterSpacing: -1.54),
        ),
        const SizedBox(height: 8),
        Text(
          'in Amazon gift cards. The top ${summary.prizePlaces} referrers get '
          '${referralMoney(summary.prizeEachMinor)} each.',
          style: referralText(
            13,
            color: referralSecondaryInk,
            weight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: Color(0xFFE2D7BC)),
        const SizedBox(height: 11),
        Text(
          'A friend counts once they finish their first game. You need at least '
          '${summary.minimumReferrals} to make the leaderboard.',
          style: referralText(11.5, height: 1.45),
        ),
      ],
    ),
  );
}

class ReferralLeaderboardRow extends StatelessWidget {
  const ReferralLeaderboardRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.isMe = false,
    this.prize = false,
    this.prizeMinor = 5000,
    this.minimumReferrals = 2,
  });
  final ReferralEntry entry;
  final VoidCallback onTap;
  final bool isMe;
  final bool prize;
  final int prizeMinor;
  final int minimumReferrals;

  @override
  Widget build(BuildContext context) {
    final qualified = entry.referralCount >= minimumReferrals;
    final meta = entry.needsReview
        ? 'Awaiting admin review'
        : prize
        ? '${entry.referralCount} friends played'
        : isMe && !qualified
        ? '${minimumReferrals - entry.referralCount} more to qualify'
        : !entry.person.ratingVisible || entry.person.division == null
        ? '${entry.referralCount} friends played'
        : 'Division ${entry.person.division}';
    return _ReferralTap(
      onTap: entry.person.username.isEmpty ? null : onTap,
      color: isMe
          ? qualified
                ? const Color(0xFFEFF6E4)
                : referralLight
          : Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              entry.rank?.toString() ?? '–',
              style: referralOutfit(13, color: FieldrushAuthTheme.muted),
            ),
          ),
          const SizedBox(width: 12),
          ReferralInitials(
            person: entry.person,
            isMe: isMe,
            qualified: qualified,
            showDivision: true,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMe ? 'You' : entry.person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: referralText(
                    13,
                    color: FieldrushAuthTheme.ink,
                    weight: isMe ? FontWeight.w800 : FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: referralText(
                    10.5,
                    color: !qualified && isMe
                        ? referralAmber
                        : FieldrushAuthTheme.muted,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (prize && (entry.prizeEligible || entry.needsReview))
            Container(
              constraints: const BoxConstraints(minWidth: 48),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                color: entry.needsReview
                    ? referralWash
                    : const Color(0xFFA7C957),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                entry.needsReview ? 'Review' : referralMoney(prizeMinor),
                textAlign: TextAlign.center,
                style: referralOutfit(
                  entry.needsReview ? 11 : 13,
                  color: const Color(0xFF1F2A0C),
                ),
              ),
            )
          else
            Column(
              children: [
                Text('${entry.referralCount}', style: referralOutfit(15)),
                const SizedBox(height: 4),
                Text(
                  'FRIENDS',
                  style: referralText(
                    8.5,
                    weight: FontWeight.w800,
                    tracking: .85,
                    height: 1,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class ReferralFriendRow extends StatelessWidget {
  const ReferralFriendRow({
    super.key,
    required this.friend,
    required this.onTap,
  });
  final ReferralFriend friend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _ReferralTap(
    onTap: friend.person.username.isEmpty ? null : onTap,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    child: Row(
      children: [
        ReferralInitials(person: friend.person, size: 32, radius: 10),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            friend.person.name,
            style: referralText(
              13.5,
              color: FieldrushAuthTheme.ink,
              weight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (friend.qualified) ...[
                const Icon(
                  Icons.check_rounded,
                  color: FieldrushAuthTheme.forest,
                  size: 16,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  friend.qualified ? 'Played' : 'Joined · no game yet',
                  textAlign: TextAlign.right,
                  style: referralText(
                    11.5,
                    color: friend.qualified
                        ? FieldrushAuthTheme.forest
                        : FieldrushAuthTheme.muted,
                    weight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ReferralTap extends StatelessWidget {
  const _ReferralTap({
    required this.child,
    required this.onTap,
    required this.padding,
    this.color = Colors.white,
  });
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}
