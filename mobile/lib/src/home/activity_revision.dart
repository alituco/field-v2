import 'package:flutter/foundation.dart';

/// Invalidates Activity and its Home unread badge after receipts or push events.
/// Screens still reload recipient-owned state; this never supplies event data.
final fieldrushActivityRevision = ValueNotifier<int>(0);

void notifyFieldrushActivityChanged() => fieldrushActivityRevision.value++;

/// A push tap opens the current account's canonical Activity, never a route or
/// entity supplied by a notification payload. Retained until Home is mounted.
final fieldrushActivityOpenRequested = ValueNotifier<bool>(false);

void requestFieldrushActivityOpen() {
  notifyFieldrushActivityChanged();
  fieldrushActivityOpenRequested.value = true;
}

void clearFieldrushActivityOpenRequest() =>
    fieldrushActivityOpenRequested.value = false;
