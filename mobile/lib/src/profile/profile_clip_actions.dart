import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/user_facing_error.dart';
import '../fixtures/fixture.dart';
import '../fixtures/fixture_detail_screen.dart';
import '../fixtures/fieldrush_match_replay_screen.dart';
import '../fixtures/fixture_repository.dart';
import '../open_queue/open_queue_repository.dart';
import '../ui/fieldrush_toast.dart';
import 'goal_clip_downloader.dart';
import 'profile.dart';
import 'profile_repository.dart';

/// Resolves the original match rather than treating the extracted clip as a
/// complete recording. Clips created before source metadata was saved have no
/// match destination.
Future<Fixture?> loadProfileClipFixture(
  ProfileHighlight highlight, {
  FixtureRepository? fixtureRepository,
  OpenQueueRepository? openQueueRepository,
}) async {
  final matchId = highlight.sourceMatchId?.trim();
  if (matchId == null || matchId.isEmpty) return null;

  final fixture = switch (highlight.sourceType) {
    ProfileHighlightSource.solo =>
      (await (openQueueRepository ?? SupabaseOpenQueueRepository())
              .getMatchDetail(matchId))
          .toFixture(),
    ProfileHighlightSource.clan =>
      await (fixtureRepository ?? SupabaseFixtureRepository()).getFixture(
        matchId,
      ),
    null => null,
  };
  // A mismatched response must never open some other game's recording.
  return fixture?.id == matchId ? fixture : null;
}

Future<void> openProfileClipFullMatch(
  BuildContext context, {
  required ProfileHighlight highlight,
  Fixture? initialFixture,
  FixtureRepository? fixtureRepository,
  OpenQueueRepository? openQueueRepository,
  ProfileRepository? profileRepository,
  GoalClipDownloader? goalClipDownloader,
}) async {
  try {
    final matches = fixtureRepository ?? SupabaseFixtureRepository();
    final soloMatches = openQueueRepository ?? SupabaseOpenQueueRepository();
    final sourceId = highlight.sourceMatchId?.trim();
    final initialMatches =
        initialFixture != null &&
        sourceId != null &&
        initialFixture.id == sourceId &&
        highlight.sourceType != null;
    final fixture = initialMatches
        ? initialFixture
        : await loadProfileClipFixture(
            highlight,
            fixtureRepository: matches,
            openQueueRepository: soloMatches,
          );
    if (!context.mounted) return;
    if (fixture == null ||
        (fixture.fullGamePlaybackUrl == null &&
            fixture.livePlaybackUrl == null)) {
      showFieldrushToast(context, 'The full match is not available yet.');
      return;
    }

    Future<Fixture> refreshFixture() async =>
        (await loadProfileClipFixture(
          highlight,
          fixtureRepository: matches,
          openQueueRepository: soloMatches,
        )) ??
        fixture;
    final sourceLabel = highlight.sourceType == ProfileHighlightSource.solo
        ? 'Solo'
        : 'Clan';
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => fixture.isFinal
            ? FieldrushMatchReplayScreen(
                fixture: fixture,
                fixtureRepository: matches,
                sourceLabel: sourceLabel,
                profileRepository: profileRepository,
                goalClipDownloader: goalClipDownloader,
                refreshFixture: refreshFixture,
              )
            : FieldrushMatchWatchScreen(
                fixture: fixture,
                fixtureRepository: matches,
                sourceLabel: sourceLabel,
                profileRepository: profileRepository,
                goalClipDownloader: goalClipDownloader,
                refreshFixture: refreshFixture,
              ),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    showFieldrushToast(
      context,
      userFacingError(
        error,
        fallback: 'Could not open the full match. Try again.',
      ),
    );
  }
}

/// Uses the public playback link already returned by the clips API. This does
/// not export private clips or expose a signed-in user's session credentials.
Future<void> shareProfileClip(
  BuildContext context,
  ProfileHighlight highlight,
) async {
  if (!highlight.isPublic) {
    showFieldrushToast(context, 'Make this clip public before sharing.');
    return;
  }
  final uri = Uri.tryParse(highlight.videoUrl?.trim() ?? '');
  if (!highlight.isReady ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    showFieldrushToast(context, 'This clip is not ready to share yet.');
    return;
  }

  final renderObject = context.findRenderObject();
  final origin = renderObject is RenderBox && renderObject.hasSize
      ? renderObject.localToGlobal(Offset.zero) & renderObject.size
      : Offset.zero & MediaQuery.sizeOf(context);
  final title = highlight.title.trim().isEmpty
      ? 'Fieldrush clip'
      : highlight.title.trim();
  try {
    await SharePlus.instance.share(
      ShareParams(
        text: '$title\n$uri',
        title: title,
        subject: title,
        sharePositionOrigin: origin,
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    showFieldrushToast(
      context,
      userFacingError(error, fallback: 'Could not share this clip. Try again.'),
    );
  }
}
