import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:field/src/profile/avatar_image.dart';
import 'package:field/src/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'removes GPS/EXIF while preserving displayed JPEG orientation',
    () async {
      final original = await _fixture('oriented-gps.jpg');
      expect(latin1.decode(original), contains('Exif'));
      expect(latin1.decode(original), contains('Fieldrush synthetic camera'));
      final clean = await sanitizeAvatarImage(original);
      _expectNoMetadata(clean);
      final image = await _decode(clean);
      try {
        expect((image.width, image.height), (8, 16));
        final rgba = (await image.toByteData())!.buffer.asUint8List();
        final upper = ((2 * image.width) + 4) * 4;
        final lower = ((13 * image.width) + 4) * 4;
        expect(rgba[upper], greaterThan(220));
        expect(rgba[upper + 2], lessThan(35));
        expect(rgba[lower], lessThan(35));
        expect(rgba[lower + 2], greaterThan(220));
      } finally {
        image.dispose();
      }
    },
  );

  test('removes PNG text and EXIF instead of forwarding the source', () async {
    final original = await _fixture('text-gps.png');
    expect(_pngChunks(original), containsAll(['tEXt', 'eXIf']));
    final clean = await sanitizeAvatarImage(original);
    _expectNoMetadata(clean);
    expect(clean, isNot(orderedEquals(original)));
  });

  for (final size in [(2400, 600), (600, 2400), (1, 1)]) {
    test(
      'bounds ${size.$1} x ${size.$2} without stretching or upscaling',
      () async {
        final source = await _png(size.$1, size.$2);
        final clean = await sanitizeAvatarImage(source);
        final image = await _decode(clean);
        try {
          expect(
            (image.width, image.height),
            switch (size) {
              (2400, 600) => (1200, 300),
              (600, 2400) => (300, 1200),
              _ => (1, 1),
            },
          );
          expect(clean.length, lessThanOrEqualTo(5 * 1024 * 1024));
        } finally {
          image.dispose();
        }
      },
    );
  }

  test('preserves transparency', () async {
    final clean = await sanitizeAvatarImage(await _png(3, 2, alpha: 100));
    final image = await _decode(clean);
    try {
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      expect(rgba[3], 100);
    } finally {
      image.dispose();
    }
  });

  test('bounds the actual first frame of an oversized animation', () async {
    final source = await _fixture('wide-animation.gif');
    final codec = await ui.instantiateImageCodec(source);
    try {
      expect(codec.frameCount, 2);
    } finally {
      codec.dispose();
    }
    final clean = await sanitizeAvatarImage(source);
    final image = await _decode(clean);
    try {
      expect((image.width, image.height), (1200, 2));
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      expect(rgba.take(4), [255, 0, 0, 255]);
      _expectNoMetadata(clean);
    } finally {
      image.dispose();
    }
  });

  for (final bytes in [
    Uint8List(0),
    Uint8List.fromList([1, 2, 3]),
    Uint8List(5 * 1024 * 1024 + 1),
  ]) {
    test(
      'rejects invalid or excessive source bytes (${bytes.length})',
      () async {
        await expectLater(sanitizeAvatarImage(bytes), throwsFormatException);
      },
    );
  }

  test(
    'repository uploads only sanitized PNG with matching path and MIME type',
    () async {
      var requests = 0;
      Uint8List? uploaded;
      final client = SupabaseClient(
        'https://fieldrush-tests.invalid',
        'test-anon-key-not-a-secret',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient.streaming((request, stream) async {
          requests++;
          expect(request.method, 'POST');
          expect(
            request.url.path,
            matches(
              r'^/storage/v1/object/profile-avatars/viewer/avatar-\d+\.png$',
            ),
          );
          final body = await stream.toBytes();
          final bodyText = latin1.decode(body);
          expect(bodyText, contains('content-type: image/png'));
          expect(bodyText, isNot(contains('image/jpeg')));
          final start = bodyText.indexOf('\x89PNG\r\n\x1a\n');
          expect(start, greaterThan(0));
          final end = bodyText.indexOf('\r\n--', start);
          uploaded = Uint8List.sublistView(body, start, end);
          _expectNoMetadata(uploaded!);
          return http.StreamedResponse(
            Stream.value(
              utf8.encode('{"Key":"profile-avatars/viewer/avatar.png"}'),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session()));
      final url = await SupabaseProfileRepository(client: client)
          .uploadCurrentUserAvatar(
            bytes: await _fixture('oriented-gps.jpg'),
            fileExtension: 'jpg',
            contentType: 'image/jpeg',
          );
      expect(requests, 1);
      expect(
        url,
        matches(r'/object/public/profile-avatars/viewer/avatar-\d+\.png$'),
      );
      final image = await _decode(uploaded!);
      expect((image.width, image.height), (8, 16));
      image.dispose();
    },
  );

  test('invalid input and signed-out requests never reach storage', () async {
    final client = SupabaseClient(
      'https://fieldrush-tests.invalid',
      'test-anon-key-not-a-secret',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (_) async => throw StateError('Unexpected upload'),
      ),
    );
    addTearDown(client.dispose);
    final repository = SupabaseProfileRepository(client: client);
    await expectLater(
      repository.uploadCurrentUserAvatar(
        bytes: await _fixture('oriented-gps.jpg'),
        fileExtension: 'jpg',
        contentType: 'image/jpeg',
      ),
      throwsA(isA<AuthException>()),
    );
    await client.auth.recoverSession(jsonEncode(_session()));
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1]),
      Uint8List(5 * 1024 * 1024 + 1),
    ]) {
      await expectLater(
        repository.uploadCurrentUserAvatar(
          bytes: bytes,
          fileExtension: 'jpg',
          contentType: 'image/jpeg',
        ),
        throwsFormatException,
      );
    }
  });
}

Future<Uint8List> _fixture(String name) =>
    File('test/fixtures/avatars/$name').readAsBytes();

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<Uint8List> _png(int width, int height, {int alpha = 255}) async {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 200;
    rgba[i + 3] = alpha;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

List<String> _pngChunks(Uint8List bytes) {
  expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  final chunks = <String>[];
  for (var offset = 8; offset < bytes.length;) {
    final length = data.getUint32(offset);
    chunks.add(ascii.decode(bytes.sublist(offset + 4, offset + 8)));
    offset += 12 + length;
  }
  return chunks;
}

void _expectNoMetadata(Uint8List bytes) {
  expect(
    _pngChunks(bytes),
    isNot(anyElement(isIn(['eXIf', 'tEXt', 'iTXt', 'zTXt']))),
  );
  expect(latin1.decode(bytes), isNot(contains('Fieldrush synthetic camera')));
}

Map<String, dynamic> _session() {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  String encoded(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token':
        '${encoded({'alg': 'HS256', 'typ': 'JWT'})}.${encoded({'sub': 'viewer', 'exp': expires})}.local-test-signature',
    'refresh_token': 'local-test-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': 'viewer',
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-10-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}
