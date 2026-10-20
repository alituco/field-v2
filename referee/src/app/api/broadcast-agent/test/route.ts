import { NextRequest, NextResponse } from "next/server";
import { getBroadcastAgentContext } from "@/lib/broadcast-pairing";
import { cloudflareCameraTestProvider, finishCameraTest, inspectCameraTest, prepareCameraTest } from "@/lib/broadcast-camera-test";

const headers = { "Cache-Control": "no-store" };

export async function GET(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;
  try {
    return NextResponse.json(await inspectCameraTest(context, cloudflareCameraTestProvider()), { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not inspect the private connection test." }, { status: 400, headers });
  }
}

export async function POST(request: NextRequest) {
  const context = await getBroadcastAgentContext(request);
  if (context instanceof NextResponse) return context;
  try {
    const body = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body) || !["prepare", "finish"].includes(body.action)) {
      throw new Error("Choose prepare or finish for the connection test.");
    }
    const provider = cloudflareCameraTestProvider();
    const result = body.action === "prepare" ? await prepareCameraTest(context, provider) : await finishCameraTest(context, provider);
    return NextResponse.json(result, { headers });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not update the private connection test." }, { status: 400, headers });
  }
}
