const projects: Record<string, string> = {
  nfdkdhdevpstfspazbfn: "staging",
  zjsjuuhborxrlmdcpvlj: "prod",
};

export function permitsScanner(
  project: string,
  claims: Record<string, unknown>,
) {
  const target = projects[project];
  const repo = "alituco/field-v2";
  const ref = claims.ref;
  if (
    !target || claims.repository_id !== "1261585393" ||
    claims.repository_owner_id !== "146518815" || claims.repository !== repo ||
    !["workflow_dispatch", "schedule"].includes(String(claims.event_name))
  ) return false;
  if (
    ref !== "refs/heads/prod" &&
    !(target === "staging" && ref === "refs/heads/staging")
  ) return false;
  return claims.job_workflow_ref ===
      repo + "/.github/workflows/replay-scan-worker.yml@" + ref &&
    claims.workflow_ref ===
      repo + "/.github/workflows/smoke-supabase-staging.yml@" + ref;
}
