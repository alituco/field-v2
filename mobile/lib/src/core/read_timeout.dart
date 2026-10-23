/// A deadline for read-only player data. Never wrap payment or booking writes:
/// an uncertain write must keep its existing idempotent recovery flow.
const fieldReadTimeout = Duration(seconds: 12);
