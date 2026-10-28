/// A competition market, not a venue's postal address city. For example a
/// pitch in Tempe can belong to the Phoenix competition.
class FieldrushCity {
  const FieldrushCity({
    required this.id,
    required this.displayName,
    required this.state,
    required this.countryCode,
    required this.timezone,
    this.active = true,
  });

  final String id;
  final String displayName;
  final String state;
  final String countryCode;
  final String timezone;
  final bool active;

  String get label => state.isEmpty ? displayName : '$displayName, $state';

  factory FieldrushCity.fromJson(Map<String, dynamic> json) => FieldrushCity(
    id: json['id'] as String,
    displayName: json['display_name'] as String,
    state: json['state'] as String? ?? '',
    countryCode: json['country_code'] as String? ?? '',
    timezone: json['timezone'] as String,
    active: json['active'] != false,
  );

  static const phoenix = FieldrushCity(
    id: 'phoenix',
    displayName: 'Phoenix',
    state: 'AZ',
    countryCode: 'US',
    timezone: 'America/Phoenix',
  );
}
