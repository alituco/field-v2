import 'dart:async';

import 'package:field/src/markets/fieldrush_city.dart';
import 'package:field/src/markets/fieldrush_city_repository.dart';
import 'package:field/src/profile/fieldrush_city_picker.dart';
import 'package:field/src/ui/fieldrush_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'city sheet scrolls a long active catalog and guards pending saves',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final response = Completer<FieldrushCity>();
      final repository = _Cities(
        cities: [
          FieldrushCity.phoenix,
          for (var index = 0; index < 14; index++) _city('city-$index'),
          _city('hidden', active: false),
        ],
        pending: response,
      );
      FieldrushCity? chosen;
      await _showPicker(tester, repository, onResult: (city) => chosen = city);
      expect(find.byType(FieldrushModal), findsOneWidget);
      expect(find.byKey(const ValueKey('city-option-hidden')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('city-option-phoenix')),
          matching: find.byIcon(Icons.radio_button_checked),
        ),
        findsOneWidget,
      );
      final last = find.byKey(const ValueKey('city-option-city-13'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pump();
      expect(repository.saved, ['city-13']);
      expect(tester.widget<ListTile>(last).onTap, isNull);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('city-picker-close')))
            .onPressed,
        isNull,
      );
      response.complete(_city('city-13'));
      await tester.pumpAndSettle();
      expect(chosen?.id, 'city-13');
      expect(find.byType(FieldrushModal), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'city loading retry shows only available cities and cancellation does not save',
    (tester) async {
      final repository = _Cities(
        cities: [_city('hidden', active: false)],
        failures: 1,
      );
      await _showPicker(tester, repository);
      expect(find.text('Could not load cities. Try again'), findsOneWidget);
      await tester.tap(find.text('Could not load cities. Try again'));
      await tester.pumpAndSettle();
      expect(find.text('No cities are available yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('city-option-hidden')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('city-picker-close')));
      await tester.pumpAndSettle();
      expect(repository.saved, isEmpty);
      expect(find.byType(FieldrushModal), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _showPicker(
  WidgetTester tester,
  _Cities repository, {
  ValueChanged<FieldrushCity?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              final city = await showFieldrushModal<FieldrushCity>(
                context: context,
                builder: (_) => FieldrushCityPicker(
                  repository: repository,
                  currentCityId: 'phoenix',
                ),
              );
              onResult?.call(city);
            },
            child: const Text('Choose city'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Choose city'));
  await tester.pumpAndSettle();
}

FieldrushCity _city(String id, {bool active = true}) => FieldrushCity(
  id: id,
  displayName: id,
  state: '',
  countryCode: 'US',
  timezone: 'America/Phoenix',
  active: active,
);

class _Cities extends Fake implements FieldrushCityRepository {
  _Cities({required this.cities, this.pending, this.failures = 0});
  final List<FieldrushCity> cities;
  final Completer<FieldrushCity>? pending;
  int failures;
  final saved = <String>[];

  @override
  Future<List<FieldrushCity>> listCities() async {
    if (failures > 0) {
      failures--;
      throw StateError('Load failed');
    }
    return cities;
  }

  @override
  Future<FieldrushCity> setPreferredCity(String id) async {
    saved.add(id);
    return pending?.future ?? cities.singleWhere((city) => city.id == id);
  }
}
