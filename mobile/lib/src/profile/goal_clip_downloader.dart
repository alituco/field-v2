import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

abstract class GoalClipDownloader {
  Future<void> downloadToGallery({
    required String url,
    required String fileName,
    ValueChanged<double>? onProgress,
  });
}

enum GoalClipDownloadFailure {
  invalidUrl,
  network,
  permissionDenied,
  notEnoughSpace,
  unsupportedFormat,
  fileSystem,
  saveFailed,
}

@immutable
class GoalClipDownloadException implements Exception {
  const GoalClipDownloadException(this.failure, {this.cause});

  final GoalClipDownloadFailure failure;
  final Object? cause;

  String get message => switch (failure) {
    GoalClipDownloadFailure.invalidUrl =>
      'This video does not have a valid download link.',
    GoalClipDownloadFailure.network =>
      'We could not download this video. Check your connection and try again.',
    GoalClipDownloadFailure.permissionDenied =>
      'Allow Field to add videos to Photos, then try again.',
    GoalClipDownloadFailure.notEnoughSpace =>
      'There is not enough space on this phone to save the video.',
    GoalClipDownloadFailure.unsupportedFormat =>
      'This recording is not available in a downloadable video format.',
    GoalClipDownloadFailure.fileSystem =>
      'Field could not prepare this video for download.',
    GoalClipDownloadFailure.saveFailed =>
      'We could not save this video to Photos. Try again.',
  };

  @override
  String toString() => message;
}

typedef GoalClipTemporaryDirectoryProvider = Future<Directory> Function();
typedef GoalClipGallerySaver = Future<void> Function(String filePath);

class DeviceGoalClipDownloader implements GoalClipDownloader {
  DeviceGoalClipDownloader({
    http.Client? client,
    GoalClipTemporaryDirectoryProvider? temporaryDirectoryProvider,
    GoalClipGallerySaver? gallerySaver,
  }) : _client = client,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _gallerySaver = gallerySaver ?? _saveWithGal;

  final http.Client? _client;
  final GoalClipTemporaryDirectoryProvider _temporaryDirectoryProvider;
  final GoalClipGallerySaver _gallerySaver;

  static Future<void> _saveWithGal(String filePath) {
    return Gal.putVideo(filePath);
  }

  @override
  Future<void> downloadToGallery({
    required String url,
    required String fileName,
    ValueChanged<double>? onProgress,
  }) async {
    final uri = _downloadUri(url);
    final requestClient = _client ?? http.Client();
    File? temporaryFile;
    IOSink? sink;

    try {
      final directory = await _temporaryDirectoryProvider();
      await directory.create(recursive: true);
      temporaryFile = File(
        '${directory.path}${Platform.pathSeparator}${_temporaryFileName(fileName)}',
      );

      http.StreamedResponse response;
      try {
        response = await requestClient.send(http.Request('GET', uri));
      } on Object catch (error) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.network,
          cause: error,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.network,
          cause: HttpException(
            'Video download returned HTTP ${response.statusCode}.',
            uri: uri,
          ),
        );
      }

      var receivedBytes = 0;
      final expectedBytes = response.contentLength;
      _reportProgress(onProgress, 0);
      sink = temporaryFile.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (expectedBytes != null && expectedBytes > 0) {
            _reportProgress(
              onProgress,
              (receivedBytes / expectedBytes).clamp(0, 1).toDouble(),
            );
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
      } on FileSystemException catch (error) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.fileSystem,
          cause: error,
        );
      } on GoalClipDownloadException {
        rethrow;
      } on Object catch (error) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.network,
          cause: error,
        );
      }

      if (receivedBytes == 0 ||
          (expectedBytes != null &&
              expectedBytes > 0 &&
              receivedBytes != expectedBytes)) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.network,
          cause: const FormatException(
            'The goal clip download was incomplete.',
          ),
        );
      }

      try {
        await _gallerySaver(temporaryFile.path);
      } on GalException catch (error) {
        throw GoalClipDownloadException(
          _failureForGal(error.type),
          cause: error,
        );
      } on GoalClipDownloadException {
        rethrow;
      } on Object catch (error) {
        throw GoalClipDownloadException(
          GoalClipDownloadFailure.saveFailed,
          cause: error,
        );
      }

      _reportProgress(onProgress, 1);
    } on GoalClipDownloadException {
      rethrow;
    } on FileSystemException catch (error) {
      throw GoalClipDownloadException(
        GoalClipDownloadFailure.fileSystem,
        cause: error,
      );
    } on Object catch (error) {
      throw GoalClipDownloadException(
        GoalClipDownloadFailure.fileSystem,
        cause: error,
      );
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } on Object {
          // Cleanup should not replace the original download error.
        }
      }
      if (temporaryFile != null) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } on Object {
          // The operating system can clear an abandoned temporary file later.
        }
      }
      if (_client == null) requestClient.close();
    }
  }
}

Uri _downloadUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasScheme ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty) {
    throw const GoalClipDownloadException(GoalClipDownloadFailure.invalidUrl);
  }
  return uri;
}

String _temporaryFileName(String requestedName) {
  var stem = requestedName.trim();
  if (stem.toLowerCase().endsWith('.mp4')) {
    stem = stem.substring(0, stem.length - 4);
  }
  stem = stem
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80);
  if (stem.isEmpty) stem = 'field-goal';
  return '${DateTime.now().microsecondsSinceEpoch}_$stem.mp4';
}

GoalClipDownloadFailure _failureForGal(GalExceptionType type) {
  return switch (type) {
    GalExceptionType.accessDenied => GoalClipDownloadFailure.permissionDenied,
    GalExceptionType.notEnoughSpace => GoalClipDownloadFailure.notEnoughSpace,
    GalExceptionType.notSupportedFormat =>
      GoalClipDownloadFailure.unsupportedFormat,
    GalExceptionType.unexpected => GoalClipDownloadFailure.saveFailed,
  };
}

void _reportProgress(ValueChanged<double>? callback, double progress) {
  callback?.call(progress.clamp(0, 1).toDouble());
}
