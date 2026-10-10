import 'package:field/src/profile/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileHighlight', () {
    test('parses a ready clan goal clip and all delivery metadata', () {
      final highlight = ProfileHighlight.fromJson({
        'id': 'clip-one',
        'title': 'Top corner vs Dilmun',
        'thumbnail_url': 'https://cdn.example.com/clip-one.jpg',
        'video_url': 'https://cdn.example.com/clip-one/video.m3u8',
        'duration': '0:30',
        'views': 42,
        'clan_tag': 'PEARL',
        'download_url': 'https://cdn.example.com/clip-one.mp4',
        'source_type': 'CLAN',
        'source_match_id': 'fixture-one',
        'source_event_id': 'goal-one',
        'provider_video_id': 'cloudflare-clip-one',
        'is_public': false,
        'status': 'READY',
        'error_message': null,
        'created_at': '2026-10-09T21:30:00Z',
      });

      expect(highlight.id, 'clip-one');
      expect(highlight.title, 'Top corner vs Dilmun');
      expect(highlight.videoUrl, endsWith('video.m3u8'));
      expect(highlight.downloadUrl, endsWith('clip-one.mp4'));
      expect(highlight.sourceType, ProfileHighlightSource.clan);
      expect(highlight.sourceMatchId, 'fixture-one');
      expect(highlight.sourceEventId, 'goal-one');
      expect(highlight.providerVideoId, 'cloudflare-clip-one');
      expect(highlight.isPublic, isFalse);
      expect(highlight.status, ProfileHighlightStatus.ready);
      expect(highlight.isReady, isTrue);
      expect(highlight.isProcessing, isFalse);
      expect(highlight.errorMessage, isNull);
      expect(highlight.views, 42);
      expect(highlight.clanTag, 'PEARL');
      expect(highlight.createdAt, DateTime.utc(2026, 10, 9, 21, 30));
      expect(highlight.copyWith(views: 43).createdAt, highlight.createdAt);
    });

    test('parses a processing solo goal before media URLs are ready', () {
      final highlight = ProfileHighlight.fromJson({
        'id': 'clip-two',
        'title': 'Late winner',
        'thumbnail_url': '',
        'video_url': null,
        'duration': '0:30',
        'views': 0,
        'download_url': null,
        'source_type': 'SOLO',
        'source_match_id': 'solo-game-one',
        'source_event_id': 'solo-goal-one',
        'provider_video_id': null,
        'status': 'PROCESSING',
      });

      expect(highlight.sourceType, ProfileHighlightSource.solo);
      expect(highlight.status, ProfileHighlightStatus.processing);
      expect(highlight.isProcessing, isTrue);
      expect(highlight.isReady, isFalse);
      expect(highlight.videoUrl, isNull);
      expect(highlight.downloadUrl, isNull);
      expect(highlight.providerVideoId, isNull);
    });

    test('retains a failed clip error without treating it as playable', () {
      final highlight = ProfileHighlight.fromJson({
        'id': 'clip-three',
        'title': 'Goal vs Riffa',
        'thumbnail_url': '',
        'duration': '0:30',
        'views': 0,
        'source_type': 'CLAN',
        'source_match_id': 'fixture-two',
        'source_event_id': 'goal-two',
        'status': 'FAILED',
        'error_message': 'The recording could not be clipped.',
      });

      expect(highlight.status, ProfileHighlightStatus.failed);
      expect(highlight.isReady, isFalse);
      expect(highlight.isProcessing, isFalse);
      expect(highlight.errorMessage, 'The recording could not be clipped.');
    });

    test('keeps legacy highlight rows readable as ready clips', () {
      final highlight = ProfileHighlight.fromJson({
        'id': 'legacy-highlight',
        'title': 'Legacy goal',
        'thumbnail_url': 'https://images.example.com/legacy.jpg',
        'video_url': 'https://videos.example.com/legacy.m3u8',
        'duration': '0:20',
        'views': 7,
        'clan_tag': 'MMAV',
      });

      expect(highlight.status, ProfileHighlightStatus.ready);
      expect(highlight.isReady, isTrue);
      expect(highlight.sourceType, isNull);
      expect(highlight.sourceMatchId, isNull);
      expect(highlight.sourceEventId, isNull);
      expect(highlight.providerVideoId, isNull);
      expect(highlight.downloadUrl, isNull);
      expect(highlight.isPublic, isTrue);
    });
  });

  test('ProfileGoalClipRequest serializes a normalized owned goal', () {
    const request = ProfileGoalClipRequest(
      sourceType: ProfileHighlightSource.solo,
      matchId: '  solo-game-one ',
      eventId: ' solo-goal-one  ',
      title: '  First-time finish ',
    );

    expect(request.sourceType, ProfileHighlightSource.solo);
    expect(request.toJson(), {
      'action': 'create',
      'source_type': 'SOLO',
      'match_id': 'solo-game-one',
      'event_id': 'solo-goal-one',
      'title': 'First-time finish',
    });
  });

  test('ProfileGoalClipRequest rejects missing source identifiers', () {
    const request = ProfileGoalClipRequest(
      sourceType: ProfileHighlightSource.clan,
      matchId: ' ',
      eventId: 'goal-one',
      title: 'Great finish',
    );

    expect(request.toJson, throwsArgumentError);
  });

  test('ProfileGoalClipRequest enforces the database title limits', () {
    const tooShort = ProfileGoalClipRequest(
      sourceType: ProfileHighlightSource.clan,
      matchId: 'fixture-one',
      eventId: 'goal-one',
      title: 'x',
    );
    final tooLong = ProfileGoalClipRequest(
      sourceType: ProfileHighlightSource.clan,
      matchId: 'fixture-one',
      eventId: 'goal-one',
      title: List.filled(81, 'x').join(),
    );

    expect(tooShort.toJson, throwsArgumentError);
    expect(tooLong.toJson, throwsArgumentError);
  });

  test('ProfileCustomClipRequest serializes a transient 60 second clip', () {
    const request = ProfileCustomClipRequest(
      sourceType: ProfileHighlightSource.clan,
      matchId: ' fixture-one ',
      startSeconds: 125.5,
      endSeconds: 185.5,
      title: '  Match clip ',
    );

    expect(request.durationSeconds, 60);
    expect(request.toJson(saveToProfile: false), {
      'action': 'custom_clip',
      'source_type': 'CLAN',
      'match_id': 'fixture-one',
      'start_seconds': 125.5,
      'end_seconds': 185.5,
      'save_to_profile': false,
      'title': 'Match clip',
    });
  });

  test('ProfileCustomClipRequest rejects clips longer than 60 seconds', () {
    const request = ProfileCustomClipRequest(
      sourceType: ProfileHighlightSource.solo,
      matchId: 'solo-one',
      startSeconds: 10,
      endSeconds: 70.1,
    );

    expect(() => request.toJson(saveToProfile: false), throwsArgumentError);
  });

  test('ProfileCustomClipRequest only requires a valid title when posting', () {
    const request = ProfileCustomClipRequest(
      sourceType: ProfileHighlightSource.solo,
      matchId: 'solo-one',
      startSeconds: 10,
      endSeconds: 40,
      title: 'x',
    );

    expect(request.toJson(saveToProfile: false), isA<Map<String, dynamic>>());
    expect(() => request.toJson(saveToProfile: true), throwsArgumentError);
  });
}
