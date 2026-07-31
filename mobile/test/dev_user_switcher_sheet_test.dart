import 'package:field/src/profile/dev_user_switcher_sheet.dart';
import 'package:field/src/profile/profile.dart';
import 'package:field/src/profile/profile_repository.dart';
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
