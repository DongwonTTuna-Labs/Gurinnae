/**
 * Generated discriminated view-model contracts for every v13 screen.
 * Each screen keeps the common runtime state shape while its screenId is
 * statically bound, preventing a route from rendering another screen's DTO.
 */
export type ScreenVmState =
  | "loading"
  | "success"
  | "empty"
  | "partial"
  | "blocked"
  | "error"
  | "offline"
  | "unauthorized"
  | "forbidden"
  | "not-found"
  | "conflict"
  | "stale"
  | "invalid-filter";

export interface ScreenVmSection {
  readonly id: string;
  readonly component: string;
  readonly state: ScreenVmState;
  readonly fields: readonly string[];
}

export interface ScreenVmV1 {
  readonly screenId: string;
  readonly route: string;
  readonly state: ScreenVmState;
  readonly title: string;
  readonly sections: readonly ScreenVmSection[];
  readonly primaryActionId: string | null;
  readonly sourceDigest: string;
  readonly runtimeTracePath: string;
}

export type PUB001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-001" };
export type PUB002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-002" };
export type PUB003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-003" };
export type PUB004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-004" };
export type PUB005ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-005" };
export type PUB006ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-006" };
export type PUB007ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-007" };
export type PUB008ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-008" };
export type PUB009ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-009" };
export type PUB010ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-010" };
export type PUB011ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-011" };
export type PUB012ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-012" };
export type PUB013ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-013" };
export type PUB014ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-014" };
export type PUB015ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-015" };
export type PUB016ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-016" };
export type PUB017ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-017" };
export type PUB018ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-018" };
export type PUB019ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-019" };
export type PUB020ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-020" };
export type PUB021ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-021" };
export type PUB022ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-022" };
export type PUB023ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-023" };
export type PUB024ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-024" };
export type PUB025ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-025" };
export type PUB026ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-026" };
export type PUB027ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-027" };
export type PUB028ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-028" };
export type PUB029ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-029" };
export type PUB030ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-030" };
export type PUB031ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-031" };
export type PUB032ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-032" };
export type PUB033ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-033" };
export type PUB034ScreenVmV1 = ScreenVmV1 & { readonly screenId: "PUB-034" };
export type RSP001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-001" };
export type RSP002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-002" };
export type RSP003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-003" };
export type RSP004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-004" };
export type RSP005ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-005" };
export type RSP006ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-006" };
export type RSP007ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-007" };
export type RSP008ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RSP-008" };
export type AUTH001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "AUTH-001" };
export type AUTH002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "AUTH-002" };
export type AUTH003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "AUTH-003" };
export type AUTH004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "AUTH-004" };
export type INT001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "INT-001" };
export type INT002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "INT-002" };
export type INT003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "INT-003" };
export type INT004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "INT-004" };
export type SIG001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SIG-001" };
export type SIG002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SIG-002" };
export type CAS001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-001" };
export type CAS002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-002" };
export type CAS003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-003" };
export type CAS004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-004" };
export type CAS005ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-005" };
export type CAS006ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-006" };
export type CAS007ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-007" };
export type CAS008ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-008" };
export type CAS009ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-009" };
export type CAS010ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-010" };
export type CAS011ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-011" };
export type CAS012ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-012" };
export type CAS013ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-013" };
export type CAS014ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-014" };
export type CAS015ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-015" };
export type CAS016ScreenVmV1 = ScreenVmV1 & { readonly screenId: "CAS-016" };
export type REV001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "REV-001" };
export type REV002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "REV-002" };
export type REV003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "REV-003" };
export type COR001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "COR-001" };
export type COR002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "COR-002" };
export type SRC001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-001" };
export type SRC002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-002" };
export type SRC003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-003" };
export type SRC004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-004" };
export type SRC005ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-005" };
export type SRC006ScreenVmV1 = ScreenVmV1 & { readonly screenId: "SRC-006" };
export type RULE001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RULE-001" };
export type RULE002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RULE-002" };
export type RULE003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RULE-003" };
export type RULE004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "RULE-004" };
export type OPS001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-001" };
export type OPS002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-002" };
export type OPS003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-003" };
export type OPS004ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-004" };
export type OPS005ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-005" };
export type OPS006ScreenVmV1 = ScreenVmV1 & { readonly screenId: "OPS-006" };
export type AUD001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "AUD-001" };
export type ADM001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "ADM-001" };
export type ADM002ScreenVmV1 = ScreenVmV1 & { readonly screenId: "ADM-002" };
export type ADM003ScreenVmV1 = ScreenVmV1 & { readonly screenId: "ADM-003" };
export type ACC001ScreenVmV1 = ScreenVmV1 & { readonly screenId: "ACC-001" };
