import { NextRequest, NextResponse } from "next/server";

export function refereeAuthError(request: NextRequest) {
  const expectedCode = process.env.REFEREE_ACCESS_CODE;

  if (!expectedCode) {
    return NextResponse.json(
      { error: "REFEREE_ACCESS_CODE is missing on the server." },
      { status: 500 },
    );
  }

  const providedCode = request.headers.get("x-referee-code")?.trim();
  if (providedCode !== expectedCode) {
    return NextResponse.json(
      { error: "Invalid referee access code." },
      { status: 401 },
    );
  }

  return null;
}
