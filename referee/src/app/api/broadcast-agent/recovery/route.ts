import { NextRequest, NextResponse } from "next/server";
import { getBroadcastAgentContext } from "@/lib/broadcast-pairing";
import { attachBroadcastRecovery, cloudflareRecoveryProvider, inspectBroadcastRecovery, prepareBroadcastRecovery } from "@/lib/broadcast-recovery";

export async function GET(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;
  try {
    const result = await inspectBroadcastRecovery(context, request.nextUrl.searchParams.get("uploadId"), cloudflareRecoveryProvider());
    return NextResponse.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not inspect this recording." }, { status: 400, headers: { "Cache-Control": "no-store" } });
  }
}

export async function POST(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;
  try {
    const body = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("Choose a recovery action.");
    const provider = cloudflareRecoveryProvider();
    const result = body.action === "prepare" ? await prepareBroadcastRecovery(context, body, provider)
      : body.action === "attach" ? await attachBroadcastRecovery(context, body, provider)
        : (() => { throw new Error("Choose prepare or attach for this recording."); })();
    return NextResponse.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not recover this recording." }, { status: 400, headers: { "Cache-Control": "no-store" } });
  }
}
