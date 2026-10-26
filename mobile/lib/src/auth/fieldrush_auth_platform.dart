import 'package:flutter/foundation.dart';

/// Keep Google available on Android and the web; native iOS uses phone sign-in.
bool get fieldrushGoogleAuthAvailable =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.iOS;
