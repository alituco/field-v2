import 'package:flutter/material.dart';
import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';

class FieldrushCityPicker extends StatefulWidget {
  const FieldrushCityPicker({
    super.key,
    required this.repository,
    this.currentCityId,
  });
  final FieldrushCityRepository repository;
  final String? currentCityId;
  @override
  State<FieldrushCityPicker> createState() => _FieldrushCityPickerState();
}

class _FieldrushCityPickerState extends State<FieldrushCityPicker> {
  late Future<List<FieldrushCity>> _future = widget.repository.listCities();
  String? _saving;
  String? _error;

  Future<void> _choose(FieldrushCity city) async {
    if (_saving != null) return;
    setState(() {
      _saving = city.id;
      _error = null;
    });
    try {
      final result = await widget.repository.setPreferredCity(city.id);
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not change city. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) => FieldrushModal(
    title: 'Choose your city',
    description:
        'Choose where to find games. Your ranking city is earned from the city where you play most this season, across both positions.',
    headerAction: IconButton(
      key: const ValueKey('city-picker-close'),
      onPressed: _saving == null ? () => Navigator.pop(context) : null,
      icon: const Icon(Icons.close),
      tooltip: 'Close',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<List<FieldrushCity>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () {
                  final next = widget.repository.listCities();
                  setState(() {
                    _future = next;
                  });
                },
                child: const Text('Could not load cities. Try again'),
              );
            }
            if (!snapshot.hasData) {
              return const FieldLoadingContent(
                label: 'Loading cities',
                rows: 2,
              );
            }
            final cities = snapshot.data!.where((c) => c.active).toList();
            if (cities.isEmpty) {
              return const Text('No cities are available yet.');
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final city in cities)
                  ListTile(
                    key: ValueKey('city-option-${city.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      city.label,
                      style: const TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    subtitle: Text(
                      _saving == city.id ? 'Saving…' : 'Find games here',
                    ),
                    trailing: Icon(
                      city.id == widget.currentCityId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: FieldrushAuthTheme.forest,
                    ),
                    onTap: _saving != null ? null : () => _choose(city),
                  ),
              ],
            );
          },
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: const TextStyle(color: FieldrushAuthTheme.danger),
            ),
          ),
      ],
    ),
  );
}
