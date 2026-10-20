import { NextRequest, NextResponse } from "next/server";
import { getBroadcastAgentContext, publicBroadcastSession } from "@/lib/broadcast-pairing";

export async function GET(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;
  return NextResponse.json(publicBroadcastSession(context), { headers: { "Cache-Control": "no-store" } });
}
