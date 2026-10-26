import 'package:flutter/foundation.dart';

/// Invalidates Activity and its Home unread badge after receipts or push events.
/// Screens still reload recipient-owned state; this never supplies event data.
final fieldrushActivityRevision = ValueNotifier<int>(0);

void notifyFieldrushActivityChanged() => fieldrushActivityRevision.value++;

/// Retained until Home mounts. A tap resolves the owner's canonical receipt;
/// legacy or unavailable receipts open Activity instead.
final fieldrushActivityOpenRequested = ValueNotifier<bool>(false);

/// A phone supplies only a receipt ID. Its destination is fetched for the
/// signed-in owner after Home mounts; no route or entity is trusted from FCM.
class FieldrushNotificationOpenRequest {
  const FieldrushNotificationOpenRequest(this.notificationId, this.userId);
  final String notificationId;
  final String userId;
}

FieldrushNotificationOpenRequest? fieldrushNotificationOpenRequest;

void requestFieldrushNotificationOpen(String notificationId, String userId) {
  fieldrushNotificationOpenRequest = FieldrushNotificationOpenRequest(
    notificationId,
    userId,
  );
  notifyFieldrushActivityChanged();
  fieldrushActivityOpenRequested.value = true;
}

void requestFieldrushActivityOpen() {
  fieldrushNotificationOpenRequest = null;
  notifyFieldrushActivityChanged();
  fieldrushActivityOpenRequested.value = true;
}

void clearFieldrushActivityOpenRequest() {
  fieldrushNotificationOpenRequest = null;
  fieldrushActivityOpenRequested.value = false;
}
