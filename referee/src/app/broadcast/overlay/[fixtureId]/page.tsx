import OverlayClient from "./overlay-client";

export default async function BroadcastOverlayPage({
  params,
}: {
  params: Promise<{ fixtureId: string }>;
}) {
  const { fixtureId } = await params;
  return <OverlayClient fixtureId={fixtureId} />;
}
