import { NextRequest, NextResponse } from "next/server";

import { refereeAuthError } from "@/lib/referee-auth";
import { loadRefereeFixtures } from "@/lib/referee-data";
import { createSupabaseAdmin } from "@/lib/supabase-admin";

export async function GET(request: NextRequest) {
  const authError = refereeAuthError(request);
  if (authError) return authError;

  try {
    const fixtures = await loadRefereeFixtures(createSupabaseAdmin());
    return NextResponse.json({ fixtures });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Could not load fixtures." },
      { status: 500 },
    );
  }
}
