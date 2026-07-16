import 'dart:io';

import 'package:field/src/profile/goal_clip_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'field-goal-download-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'streams an MP4 to the gallery and removes the temporary file',
    () async {
      final sourceBytes = <int>[1, 2, 3, 4, 5, 6];
      final progress = <double>[];
      String? savedPath;
      List<int>? savedBytes;
      final client = MockClient.streaming((request, bodyStream) async {
        expect(request.method, 'GET');
        expect(request.url, Uri.parse('https://media.example/goal.mp4'));
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            sourceBytes.sublist(0, 3),
            sourceBytes.sublist(3),
          ]),
          200,
          contentLength: sourceBytes.length,
        );
      });
      final downloader = DeviceGoalClipDownloader(
        client: client,
        temporaryDirectoryProvider: () async => temporaryDirectory,
        gallerySaver: (path) async {
          savedPath = path;
          savedBytes = await File(path).readAsBytes();
        },
      );

      await downloader.downloadToGallery(
        url: 'https://media.example/goal.mp4',
        fileName: 'Winner / Goal?.mp4',
        onProgress: progress.add,
      );

      expect(savedBytes, sourceBytes);
      expect(savedPath, isNotNull);
      expect(savedPath, endsWith('_Winner_Goal.mp4'));
      expect(await File(savedPath!).exists(), isFalse);
      expect(progress.first, 0);
      expect(progress, contains(0.5));
      expect(progress.last, 1);
    },
  );

  test('supports downloads without a content length', () async {
    final progress = <double>[];
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[7, 8, 9]),
        200,
      );
    });
    final downloader = DeviceGoalClipDownloader(
      client: client,
      temporaryDirectoryProvider: () async => temporaryDirectory,
      gallerySaver: (_) async {},
    );

    await downloader.downloadToGallery(
      url: 'https://media.example/goal.mp4',
      fileName: 'Goal',
      onProgress: progress.add,
    );

    expect(progress, <double>[0, 1]);
  });

  test('rejects invalid links before creating a temporary file', () async {
    var requestedDirectory = false;
    final downloader = DeviceGoalClipDownloader(
      temporaryDirectoryProvider: () async {
        requestedDirectory = true;
        return temporaryDirectory;
      },
      gallerySaver: (_) async {},
    );

    await expectLater(
      downloader.downloadToGallery(url: 'not a URL', fileName: 'Goal'),
      throwsA(
        isA<GoalClipDownloadException>().having(
          (error) => error.failure,
          'failure',
          GoalClipDownloadFailure.invalidUrl,
        ),
      ),
    );
    expect(requestedDirectory, isFalse);
  });

  test('does not save an unsuccessful HTTP response', () async {
    var galleryCalled = false;
    final client = MockClient((request) async => http.Response('', 404));
    final downloader = DeviceGoalClipDownloader(
      client: client,
      temporaryDirectoryProvider: () async => temporaryDirectory,
      gallerySaver: (_) async => galleryCalled = true,
    );

    await expectLater(
      downloader.downloadToGallery(
        url: 'https://media.example/missing.mp4',
        fileName: 'Goal',
      ),
      throwsA(
        isA<GoalClipDownloadException>().having(
          (error) => error.failure,
          'failure',
          GoalClipDownloadFailure.network,
        ),
      ),
    );
    expect(galleryCalled, isFalse);
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  test('rejects and cleans up an incomplete response', () async {
    String? attemptedPath;
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2, 3]),
        200,
        contentLength: 5,
      );
    });
    final downloader = DeviceGoalClipDownloader(
      client: client,
      temporaryDirectoryProvider: () async => temporaryDirectory,
      gallerySaver: (path) async => attemptedPath = path,
    );

    await expectLater(
      downloader.downloadToGallery(
        url: 'https://media.example/incomplete.mp4',
        fileName: 'Goal',
      ),
      throwsA(
        isA<GoalClipDownloadException>().having(
          (error) => error.failure,
          'failure',
          GoalClipDownloadFailure.network,
        ),
      ),
    );
    expect(attemptedPath, isNull);
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  for (final testCase in <(GalExceptionType, GoalClipDownloadFailure)>[
    (GalExceptionType.accessDenied, GoalClipDownloadFailure.permissionDenied),
    (GalExceptionType.notEnoughSpace, GoalClipDownloadFailure.notEnoughSpace),
    (
      GalExceptionType.notSupportedFormat,
      GoalClipDownloadFailure.unsupportedFormat,
    ),
    (GalExceptionType.unexpected, GoalClipDownloadFailure.saveFailed),
  ]) {
    test('maps ${testCase.$1.name} gallery errors and cleans up', () async {
      String? savedPath;
      final client = MockClient(
        (request) async => http.Response.bytes(<int>[1, 2, 3], 200),
      );
      final downloader = DeviceGoalClipDownloader(
        client: client,
        temporaryDirectoryProvider: () async => temporaryDirectory,
        gallerySaver: (path) async {
          savedPath = path;
          throw GalException(
            type: testCase.$1,
            platformException: PlatformException(code: testCase.$1.name),
            stackTrace: StackTrace.current,
          );
        },
      );

      await expectLater(
        downloader.downloadToGallery(
          url: 'https://media.example/goal.mp4',
          fileName: 'Goal',
        ),
        throwsA(
          isA<GoalClipDownloadException>().having(
            (error) => error.failure,
            'failure',
            testCase.$2,
          ),
        ),
      );
      expect(savedPath, isNotNull);
      expect(await File(savedPath!).exists(), isFalse);
    });
  }
}
