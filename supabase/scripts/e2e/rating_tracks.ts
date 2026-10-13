export type RatingTrack = "OUTFIELD" | "GOALKEEPER";

export function ratingTrackForRole(role: string): RatingTrack {
  if (role === "GK") return "GOALKEEPER";
  if (role === "DEF" || role === "MID" || role === "ATT") return "OUTFIELD";
  throw new Error(`Unsupported E2E booked position: ${role}.`);
}

/** Each manifest baseline belongs to the position that actor will actually book. */
export function bookedRoleRatingBaselines(
  rows: Array<{
    profile_id: string;
    rating_track: string;
    skill_rating: number;
  }>,
  rolesByProfile: Record<string, string>,
): Record<string, number> {
  const ratings: Record<string, number> = {};
  for (const [profileId, role] of Object.entries(rolesByProfile)) {
    const track = ratingTrackForRole(role);
    const matches = rows.filter((row) =>
      row.profile_id === profileId && row.rating_track === track
    );
    if (
      matches.length !== 1 || !Number.isFinite(matches[0].skill_rating) ||
      matches[0].skill_rating < 0
    ) {
      throw new Error(
        `Missing or invalid ${track} SR for E2E player ${profileId}.`,
      );
    }
    ratings[profileId] = matches[0].skill_rating;
  }
  return ratings;
}
