import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

/// The game card and lineup remain recognisable while their data arrives.
class FieldrushGameLoading extends StatelessWidget {
  const FieldrushGameLoading({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading game details',
    liveRegion: true,
    child: const ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 16),
          FieldSkeleton(height: 218, radius: 24),
          SizedBox(height: 16),
          FieldSkeleton(height: 45, radius: 16),
          FieldLoadingContent(label: 'Loading lineup', rows: 3),
        ],
      ),
    ),
  );
}

class FieldrushPriceLoading extends StatelessWidget {
  const FieldrushPriceLoading({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Checking your exact total',
    liveRegion: true,
    child: ExcludeSemantics(
      child: Column(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  FieldSkeleton(width: i == 2 ? 54 : 124, height: 14),
                  const Spacer(),
                  const FieldSkeleton(width: 64, height: 17),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
