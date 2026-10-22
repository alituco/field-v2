import 'package:flutter/material.dart';

/// Fills a player photo's square frame without stretching its source image.
/// Callers own the clipping, background, and initials style for their surface.
class FieldrushAvatarImage extends StatelessWidget {
  const FieldrushAvatarImage({
    super.key,
    required this.size,
    required this.fallback,
    this.url,
    this.image,
    this.imageKey,
    this.excludeFromSemantics = false,
    this.semanticLabel,
  }) : assert(size > 0),
       assert(url == null || image == null);

  final double size;
  final Widget fallback;
  final String? url;
  final ImageProvider? image;
  final Key? imageKey;
  final bool excludeFromSemantics;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final photoUrl = url?.trim();
    final provider =
        image ??
        (photoUrl == null || photoUrl.isEmpty ? null : NetworkImage(photoUrl));
    return SizedBox.square(
      dimension: size,
      child: provider == null
          ? fallback
          : Image(
              key: imageKey,
              image: provider,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              excludeFromSemantics: excludeFromSemantics,
              semanticLabel: semanticLabel,
              frameBuilder: (context, child, frame, synchronous) =>
                  frame == null && !synchronous ? fallback : child,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
    );
  }
}
