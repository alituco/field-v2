import { permitsScanner } from "./auth.ts";
const staging = "nfdkdhdevpstfspazbfn", prod = "zjsjuuhborxrlmdcpvlj";
function claims(branch: string) {
  const ref = "refs/heads/" + branch, repo = "alituco/field-v2";
  return {
    repository_id: "1261585393",
    repository_owner_id: "146518815",
    repository: repo,
    ref,
    event_name: "workflow_dispatch",
    job_workflow_ref: repo + "/.github/workflows/replay-scan-worker.yml@" + ref,
    workflow_ref: repo + "/.github/workflows/smoke-supabase-staging.yml@" + ref,
  };
}
Deno.test("scope worker identity to deployed project, workflow and ref", () => {
  if (
    !permitsScanner(staging, claims("staging")) ||
    !permitsScanner(prod, claims("prod"))
  ) throw new Error("Trusted job denied");
  for (
    const c of [
      claims("staging"),
      claims("main"),
      { ...claims("prod"), event_name: "pull_request_target" },
      { ...claims("prod"), job_workflow_ref: "other" },
      { ...claims("prod"), repository_id: "1" },
    ]
  ) {
    if (permitsScanner(prod, c)) throw new Error("Untrusted job allowed");
  }
});
