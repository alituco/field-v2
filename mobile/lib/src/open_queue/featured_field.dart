import 'open_queue.dart';

/// Public location information selected by Ops for one competition city.
class FeaturedField {
  const FeaturedField({
    required this.id,
    required this.name,
    required this.address,
    required this.cityId,
    required this.directionsUri,
  });

  final String id;
  final String name;
  final String? address;
  final String? cityId;
  final Uri? directionsUri;

  factory FeaturedField.fromJson(Map<String, dynamic> json) {
    final address = [
      for (final key in ['address', 'city', 'state', 'country_code'])
        if ((json[key]?.toString().trim() ?? '').isNotEmpty)
          json[key].toString().trim(),
    ].join(', ');
    final latitude = (json['latitude'] as num?)?.toDouble();
    final longitude = (json['longitude'] as num?)?.toDouble();
    final coordinatesValid =
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180;
    return FeaturedField(
      id: json['id'] as String,
      name: json['name'] as String,
      address: address.isEmpty ? null : address,
      cityId: json['market_city_id'] as String?,
      directionsUri: coordinatesValid || address.isNotEmpty
          ? Uri.https('www.google.com', '/maps/search/', {
              'api': '1',
              'query': coordinatesValid ? '$latitude,$longitude' : address,
            })
          : null,
    );
  }

  factory FeaturedField.fromGame(OpenQueueGame game) => FeaturedField(
    id: game.fieldId ?? '',
    name: game.venue,
    address: game.locationLabel,
    cityId: game.marketCityId,
    directionsUri: game.directionsUri,
  );

  bool matchesGame(OpenQueueGame game) =>
      (id.isNotEmpty ? game.fieldId == id : game.venue == name) &&
      game.locationLabel == address;
}
