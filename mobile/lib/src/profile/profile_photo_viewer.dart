import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

/// Enlarges a public profile photo without changing profile navigation.
Future<void> showProfilePhoto(
  BuildContext context, {
  required String url,
  required String name,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (context) => Dialog.fullscreen(
    key: const ValueKey('profile-photo-viewer'),
    backgroundColor: Colors.black,
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: 'Close photo',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
        title: Text(name),
      ),
      body: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Image.network(
              url,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.contain,
              semanticLabel: '$name’s profile photo',
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(
                      child: FieldLoadingIndicator(
                        label: 'Loading photo',
                        color: Colors.white,
                      ),
                    ),
              errorBuilder: (context, error, stack) => const Center(
                child: Text(
                  'Photo unavailable',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
