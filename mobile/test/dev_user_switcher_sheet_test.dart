import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/profile/dev_user_switcher_sheet.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('developer user switch uses the Field confirmation dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeProfileRepository();
    String? switchedTo;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDevUserSwitcher(
                context: context,
                profileRepository: repository,
                currentUserId: 'current-user',
                onSwitchUser: (profileId) async => switchedTo = profileId,
              ),
              child: const Text('Choose user'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Choose user'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ali Altaraif'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('field-confirmation-dialog')),
      findsOneWidget,
    );
    expect(find.text('Continue as Ali Altaraif?'), findsOneWidget);
    expect(find.text('@aliiii'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('field-confirmation-cancel')));
    await tester.pumpAndSettle();
    expect(switchedTo, isNull);
    expect(find.text('Swap profile'), findsOneWidget);

    await tester.tap(find.text('Ali Altaraif'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-confirmation-confirm')));
    await tester.pumpAndSettle();

    expect(switchedTo, 'other-user');
    expect(find.text('Swap profile'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile picker keeps search and the disabled current user', (
    tester,
  ) async {
    String? switchedTo;
    await _open(tester, onSwitchUser: (id) async => switchedTo = id);
    expect(find.byType(FieldrushModal), findsOneWidget);
    expect(find.text('Staging admin only'.toUpperCase()), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Swap profile')).style!.fontFamily,
      'Outfit',
    );
    expect(
      Theme.of(tester.element(find.text('Swap profile'))).colorScheme.surface,
      FieldrushAuthTheme.cream,
    );
    final current = find.byKey(const ValueKey('dev-user-option-current-user'));
    expect(tester.widget<InkWell>(current).onTap, isNull);
    expect(find.text('CURRENT'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('dev-user-search')),
      'aliiii',
    );
    await tester.pumpAndSettle();
    expect(find.text('Ali Altaraif'), findsOneWidget);
    expect(find.text('Dana Alawi'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('dev-user-search')),
      'missing',
    );
    await tester.pumpAndSettle();
    expect(find.text('No users found'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Dana Alawi'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dev-user-switcher-close')));
    await tester.pumpAndSettle();
    expect(switchedTo, isNull);
    expect(find.byType(FieldrushModal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile picker scrolls with a keyboard on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, onSwitchUser: (_) async {}, scale: 1.4, keyboard: 240);
    await tester.enterText(
      find.byKey(const ValueKey('dev-user-search')),
      'Ali',
    );
    await tester.pumpAndSettle();
    final close = find.byKey(const ValueKey('dev-user-switcher-close'));
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(FieldrushModal), findsNothing);
  });
}

Future<void> _open(
  WidgetTester tester, {
  required Future<void> Function(String) onSwitchUser,
  double scale = 1,
  double keyboard = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDevUserSwitcher(
              context: context,
              profileRepository: _FakeProfileRepository(),
              currentUserId: 'current-user',
              onSwitchUser: onSwitchUser,
            ),
            child: const Text('Open profiles'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open profiles'));
  await tester.pumpAndSettle();
}

class _FakeProfileRepository implements ProfileRepository {
  @override
  String? get currentUserId => 'current-user';

  @override
  Future<List<DevProfileOption>> listProfilesForDevelopment() async => const [
    DevProfileOption(
      id: 'current-user',
      displayName: 'Dana Alawi',
      username: 'bh_dana_08',
    ),
    DevProfileOption(
      id: 'other-user',
      displayName: 'Ali Altaraif',
      username: 'aliiii',
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
