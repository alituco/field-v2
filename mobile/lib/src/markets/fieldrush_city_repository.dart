import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fieldrush_city.dart';

/// Invalidates kept-alive discovery screens after a successful Settings edit.
final fieldrushCityRevision = ValueNotifier<int>(0);

abstract interface class FieldrushCityRepository {
  Future<List<FieldrushCity>> listCities();
  Future<FieldrushCity> loadPreferredCity();
  Future<FieldrushCity> setPreferredCity(String id);
}

class SupabaseFieldrushCityRepository implements FieldrushCityRepository {
  SupabaseFieldrushCityRepository({SupabaseClient? client})
    : _injected = client;

  final SupabaseClient? _injected;
  SupabaseClient get _client => _injected ?? Supabase.instance.client;

  @override
  Future<List<FieldrushCity>> listCities() async {
    final value = await _client.rpc('list_fieldrush_cities');
    return [
      for (final row in value as List)
        FieldrushCity.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<FieldrushCity> loadPreferredCity() async {
    final results = await Future.wait<dynamic>([
      _client.rpc('get_my_fieldrush_account').then((value) => value),
      listCities(),
    ]);
    return _resolve(
      Map<String, dynamic>.from(results[0] as Map),
      results[1] as List<FieldrushCity>,
    );
  }

  @override
  Future<FieldrushCity> setPreferredCity(String id) async {
    final account = await _client.rpc(
      'set_my_fieldrush_city',
      params: {'city_id_to_use': id},
    );
    final city = _resolve(
      Map<String, dynamic>.from(account as Map),
      await listCities(),
    );
    fieldrushCityRevision.value++;
    return city;
  }

  FieldrushCity _resolve(
    Map<String, dynamic> account,
    List<FieldrushCity> cities,
  ) {
    final id = account['preferred_city_id'];
    final preferred = cities.where((city) => city.id == id).firstOrNull;
    if (preferred == null) {
      throw StateError('Choose an available city in Account settings.');
    }
    return preferred;
  }
}
