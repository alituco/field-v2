import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../reliability/reliability.dart';
import '../notifications/fieldrush_push.dart';
import '../home/activity_revision.dart';
import '../ui/field_loading.dart';

enum YouNotificationOption {
  gameReminders(
    'game_reminders',
    'Game reminders',
    'A reminder before your next game.',
  ),
  openSpots(
    'open_spots',
    'Open solo spots',
    'Available positions in your city that you can book.',
  ),
  clanCallups(
    'clan_callups',
    'Clan call-ups',
    'When your captain adds you to a squad.',
  ),
  partyInvites(
    'party_invites',
    'Party invites',
    'Invitations to play on the same team.',
  ),
  ladderMoves(
    'ladder_moves',
    'Ladder moves',
    'Changes to your place in the rankings.',
  ),
  replaysReady(
    'replays_ready',
    'Replays ready',
    'When a recording of your game is ready.',
  ),
  newsAndOffers(
    'news_and_offers',
    'News & offers',
    'Updates and offers from Fieldrush.',
  );

  const YouNotificationOption(this.key, this.label, this.description);
  final String key;
  final String label;
  final String description;
}

class YouNotificationPreferences {
  const YouNotificationPreferences({
    this.gameReminders = true,
    this.openSpots = false,
    this.clanCallups = true,
    this.partyInvites = true,
    this.ladderMoves = true,
    this.replaysReady = false,
    this.newsAndOffers = false,
  });

  final bool gameReminders;
  final bool openSpots;
  final bool clanCallups;
  final bool partyInvites;
  final bool ladderMoves;
  final bool replaysReady;
  final bool newsAndOffers;

  int get enabledCount => toJson().values.where((value) => value).length;

  bool valueFor(YouNotificationOption option) => toJson()[option.key]!;

  YouNotificationPreferences copyWith({
    bool? gameReminders,
    bool? openSpots,
    bool? clanCallups,
    bool? partyInvites,
    bool? ladderMoves,
    bool? replaysReady,
    bool? newsAndOffers,
  }) => YouNotificationPreferences(
    gameReminders: gameReminders ?? this.gameReminders,
    openSpots: openSpots ?? this.openSpots,
    clanCallups: clanCallups ?? this.clanCallups,
    partyInvites: partyInvites ?? this.partyInvites,
    ladderMoves: ladderMoves ?? this.ladderMoves,
    replaysReady: replaysReady ?? this.replaysReady,
    newsAndOffers: newsAndOffers ?? this.newsAndOffers,
  );

  YouNotificationPreferences withValue(
    YouNotificationOption option,
    bool value,
  ) => YouNotificationPreferences.fromJson({...toJson(), option.key: value});

  Map<String, bool> toJson() => {
    'game_reminders': gameReminders,
    'open_spots': openSpots,
    'clan_callups': clanCallups,
    'party_invites': partyInvites,
    'ladder_moves': ladderMoves,
    'replays_ready': replaysReady,
    'news_and_offers': newsAndOffers,
  };

  factory YouNotificationPreferences.fromJson(Map<String, dynamic> json) {
    bool read(String key) {
      final value = json[key];
      if (value is! bool) {
        throw const FormatException(
          'Notification preferences are unavailable.',
        );
      }
      return value;
    }

    return YouNotificationPreferences(
      gameReminders: read('game_reminders'),
      openSpots: json.containsKey('open_spots') ? read('open_spots') : false,
      clanCallups: read('clan_callups'),
      partyInvites: read('party_invites'),
      ladderMoves: read('ladder_moves'),
      replaysReady: read('replays_ready'),
      newsAndOffers: read('news_and_offers'),
    );
  }
}

class YouWallet {
  YouWallet({
    required this.primaryBalance,
    required List<FieldWalletBalance> balances,
  }) : balances = List.unmodifiable(balances);

  final FieldWalletBalance primaryBalance;
  final List<FieldWalletBalance> balances;

  String get label => primaryBalance.label;

  List<FieldWalletBalance> get otherBalances => balances
      .where(
        (balance) =>
            balance.currency != primaryBalance.currency &&
            balance.balanceFils != 0,
      )
      .toList(growable: false);

  factory YouWallet.fromJson(Map<String, dynamic> json) {
    FieldWalletBalance read(Map<String, dynamic> row) {
      final currency = row['currency'];
      final rawAmount = row['balance_fils'];
      final amount = rawAmount is int
          ? rawAmount
          : rawAmount is String
          ? int.tryParse(rawAmount)
          : null;
      if ((currency != 'USD' && currency != 'BHD') || amount == null) {
        throw const FormatException('Your wallet balance is unavailable.');
      }
      return FieldWalletBalance(
        currency: currency as String,
        balanceFils: amount,
      );
    }

    final primary = read(json);
    final rawBalances = json['balances'];
    if (rawBalances is! List) {
      throw const FormatException('Your wallet balance is unavailable.');
    }
    final balances = <String, FieldWalletBalance>{primary.currency: primary};
    for (final raw in rawBalances) {
      if (raw is! Map) {
        throw const FormatException('Your wallet balance is unavailable.');
      }
      final balance = read(Map<String, dynamic>.from(raw));
      balances[balance.currency] = balance;
    }
    return YouWallet(
      primaryBalance: primary,
      balances: balances.values.toList(),
    );
  }
}

abstract class YouSettingsRepository {
  Future<YouNotificationPreferences> loadNotifications();
  Future<YouNotificationPreferences> saveNotifications(
    YouNotificationPreferences preferences,
  );
  Future<YouWallet> loadWallet();
}

class SupabaseYouSettingsRepository implements YouSettingsRepository {
  SupabaseYouSettingsRepository({SupabaseClient? client}) : _supabase = client;

  final SupabaseClient? _supabase;
  SupabaseClient get _client => _supabase ?? Supabase.instance.client;

  @override
  Future<YouNotificationPreferences> loadNotifications() async =>
      _preferences(await _client.rpc('get_my_profile_settings'));

  @override
  Future<YouNotificationPreferences> saveNotifications(
    YouNotificationPreferences preferences,
  ) async => _preferences(
    await _client.rpc(
      'update_my_notification_preferences',
      params: {'preferences_to_use': preferences.toJson()},
    ),
  );

  @override
  Future<YouWallet> loadWallet() async =>
      YouWallet.fromJson(_object(await _client.rpc('get_my_fieldrush_wallet')));

  YouNotificationPreferences _preferences(Object? response) =>
      YouNotificationPreferences.fromJson(
        _object(_object(response)['notifications']),
      );

  Map<String, dynamic> _object(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const FormatException('Account details are unavailable.');
  }
}

class YouNotificationsScreen extends StatefulWidget {
  const YouNotificationsScreen({super.key, required this.repository});
  final YouSettingsRepository repository;

  @override
  State<YouNotificationsScreen> createState() => _YouNotificationsScreenState();
}

class _YouNotificationsScreenState extends State<YouNotificationsScreen> {
  YouNotificationPreferences? _preferences;
  YouNotificationPreferences? _failedSave;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preferences = await widget.repository.loadNotifications();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your preferences.';
      });
    }
  }

  Future<void> _save(YouNotificationPreferences preferences) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _failedSave = null;
    });
    try {
      final saved = await widget.repository.saveNotifications(preferences);
      if (!mounted) return;
      setState(() {
        _preferences = saved;
        _saving = false;
      });
      notifyFieldrushActivityChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failedSave = preferences;
        _error =
            'Could not save this change. Your previous preferences are still shown.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _preferences;
    return _SettingsScaffold(
      title: 'Notifications',
      trailing: _saving
          ? Text('Saving…', style: _body(11, weight: FontWeight.w700))
          : preferences == null
          ? null
          : Text(
              '${preferences.enabledCount} on',
              style: _body(11, weight: FontWeight.w700),
            ),
      children: [
        if (_loading)
          const _Loading()
        else ...[
          if (_error != null)
            _ErrorCard(
              message: _error!,
              onRetry: () =>
                  _failedSave == null ? _load() : _save(_failedSave!),
            ),
          if (preferences != null) ...[
            AnimatedBuilder(
              animation: FieldrushPush.instance,
              builder: (context, _) {
                final push = FieldrushPush.instance;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _WhiteCard(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ON THIS PHONE',
                            style: _body(11, weight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(push.status, style: _body(12)),
                          if (push.canRefreshSetup)
                            TextButton(
                              onPressed: push.refreshSetup,
                              child: const Text(
                                'Check phone notification setup',
                              ),
                            ),
                          if (push.canEnable || push.phoneEnabled) ...[
                            const SizedBox(height: 10),
                            TextButton(
                              key: const Key('you-enable-phone-notifications'),
                              onPressed: push.busy
                                  ? null
                                  : () => push.phoneEnabled
                                        ? push.disableOnThisPhone()
                                        : push.enableOnThisPhone(),
                              child: Text(
                                push.phoneEnabled
                                    ? 'Turn off on this phone'
                                    : 'Enable on this phone',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            _WhiteCard(
              child: Column(
                children: [
                  for (final option in YouNotificationOption.values) ...[
                    if (option.index > 0)
                      const Divider(height: 1, color: _divider),
                    Semantics(
                      enabled: !_saving,
                      child: InkWell(
                        onTap: _saving
                            ? null
                            : () => _save(
                                preferences.withValue(
                                  option,
                                  !preferences.valueFor(option),
                                ),
                              ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.label,
                                      style: _body(
                                        13.5,
                                        color: _ink,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(option.description, style: _body(11)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Switch.adaptive(
                                key: ValueKey('you-notification-${option.key}'),
                                value: preferences.valueFor(option),
                                activeTrackColor: _forest,
                                onChanged: _saving
                                    ? null
                                    : (value) => _save(
                                        preferences.withValue(option, value),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'These choices apply to Activity and registered phones. Booking, payment, safety, support and account notices stay on. Device permissions are managed in your phone settings.',
                style: _body(11.5),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class YouWalletScreen extends StatefulWidget {
  const YouWalletScreen({super.key, required this.repository});
  final YouSettingsRepository repository;

  @override
  State<YouWalletScreen> createState() => _YouWalletScreenState();
}

class _YouWalletScreenState extends State<YouWalletScreen> {
  late Future<YouWallet> _wallet;

  @override
  void initState() {
    super.initState();
    _wallet = widget.repository.loadWallet();
  }

  @override
  Widget build(BuildContext context) => _SettingsScaffold(
    title: 'Wallet',
    children: [
      FutureBuilder<YouWallet>(
        future: _wallet,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _Loading();
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return _ErrorCard(
              message: 'Could not load your wallet balance.',
              onRetry: () => setState(() {
                _wallet = widget.repository.loadWallet();
              }),
            );
          }
          final wallet = snapshot.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2F5C39), Color(0xFF1F3D26)],
                  ),
                ),
                child: CustomPaint(
                  painter: _WalletPattern(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 16,
                              color: Color(0xFFC7DD9B),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'FIELDRUSH WALLET',
                                style: _body(
                                  10,
                                  color: const Color(0xFFC7DD9B),
                                  weight: FontWeight.w800,
                                ).copyWith(letterSpacing: 1.4),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            wallet.label,
                            style: const TextStyle(
                              fontFamily: 'Outfit',
                              fontSize: 52,
                              height: .95,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 11),
                        Text(
                          '${wallet.primaryBalance.currency} credit held in your wallet',
                          style: _body(
                            12,
                            color: const Color(0xFFE4F0D5),
                            weight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Your existing Fieldrush wallet credit is shown here. Refunds for new bookings return to the original payment method.',
                  style: _body(12),
                ),
              ),
              if (wallet.otherBalances.isNotEmpty) ...[
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'OTHER CURRENCIES',
                    style: _body(
                      10.5,
                      weight: FontWeight.w800,
                    ).copyWith(letterSpacing: 1.3),
                  ),
                ),
                const SizedBox(height: 11),
                _WhiteCard(
                  child: Column(
                    children: [
                      for (final balance in wallet.otherBalances)
                        Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  balance.currency,
                                  style: _body(
                                    13.5,
                                    color: _ink,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                balance.label,
                                style: _body(
                                  14,
                                  color: _forest,
                                  weight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Balances are kept separately in each currency.',
                    style: _body(11.5),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    ],
  );
}

class YouPaymentMethodsScreen extends StatelessWidget {
  const YouPaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final walletName = kIsWeb
        ? null
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => 'Google Pay',
            TargetPlatform.iOS => 'Apple Pay',
            _ => null,
          };
    return _SettingsScaffold(
      title: 'Payment methods',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Choose your payment method when you book a game.',
            style: _body(12.5),
          ),
        ),
        const SizedBox(height: 16),
        _WhiteCard(
          child: Column(
            children: [
              _PaymentRow(
                icon: Icons.credit_card_rounded,
                title: 'Visa & Mastercard',
                description: 'Enter your card details securely at checkout.',
              ),
              if (walletName != null) ...[
                const Divider(height: 1, color: _divider),
                _PaymentRow(
                  icon: defaultTargetPlatform == TargetPlatform.android
                      ? Icons.phone_android_rounded
                      : Icons.phone_iphone_rounded,
                  title: walletName,
                  description:
                      'Shown at checkout when supported on your device and available for your payment.',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Saved cards are not available in Fieldrush yet.',
            style: _body(11.5),
          ),
        ),
      ],
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 26, color: _forest),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: _body(13.5, color: _ink, weight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(description, style: _body(11.5)),
            ],
          ),
        ),
      ],
    ),
  );
}

const _cream = Color(0xFFFAF7EF);
const _ink = Color(0xFF22301F);
const _forest = Color(0xFF386641);
const _muted = Color(0xFF55654A);
const _border = Color(0xFFE6DFCB);
const _divider = Color(0xFFF0ECE0);

TextStyle _body(
  double size, {
  Color color = _muted,
  FontWeight weight = FontWeight.w600,
}) => TextStyle(
  fontFamily: 'PlusJakartaSans',
  fontSize: size,
  height: 1.4,
  color: color,
  fontWeight: weight,
);

class _SettingsScaffold extends StatelessWidget {
  const _SettingsScaffold({
    required this.title,
    required this.children,
    this.trailing,
  });
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _cream,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
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
                          color: _ink,
                          size: 23,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 18,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                      letterSpacing: -.2,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
              children: children,
            ),
          ),
        ],
      ),
    ),
  );
}

class _WhiteCard extends StatelessWidget {
  const _WhiteCard({required this.child});
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

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const _WhiteCard(
    child: FieldLoadingContent(
      label: 'Loading settings',
      rows: 5,
      compact: true,
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: _WhiteCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: _body(12.5, color: const Color(0xFFA63A3C))),
            const SizedBox(height: 6),
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Retry',
                style: _body(12.5, color: _forest, weight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _WalletPattern extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final lines = Paint()
      ..color = Colors.white.withValues(alpha: .05)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height * .25, size.height),
        lines,
      );
    }
    canvas.drawCircle(
      Offset(size.width - 36, size.height - 16),
      100,
      Paint()
        ..color = Colors.white.withValues(alpha: .1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _WalletPattern oldDelegate) => false;
}
