import * as fs from "fs";
import * as path from "path";
import { TONES } from "@/shared/tokens";
import { FinancingStatus, financingLabel, financingTone } from "./financing-tone";

const MIGRATIONS = path.resolve(__dirname, "../../../../supabase/migrations");

/** The status list of the last migration that (re)defines monvelo_financings_status_check. */
function statusesFromMigrations(): string[] {
  const files = fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort();
  let found: string[] | null = null;
  for (const f of files) {
    const sql = fs.readFileSync(path.join(MIGRATIONS, f), "utf8");
    const re = /add constraint monvelo_financings_status_check\s+check\s*\(\s*status in\s*\(([^)]*)\)/gi;
    for (const m of sql.matchAll(re)) found = [...m[1].matchAll(/'([A-Z_]+)'/g)].map((x) => x[1]);
  }
  if (!found) throw new Error("no monvelo_financings_status_check found");
  return found;
}

describe("financingTone (Spec B §4.2)", () => {
  it("covers exactly the statuses of the database CHECK", () => {
    expect([...FinancingStatus.options].sort()).toEqual(statusesFromMigrations().sort());
  });
  it("maps every status to a tone and a label in words", () => {
    for (const s of FinancingStatus.options) {
      expect(TONES).toContain(financingTone[s]);
      expect(financingLabel[s].length).toBeGreaterThan(2);
    }
  });
  it("matches the spec's table", () => {
    expect(financingTone).toEqual({
      REQUESTED: "pending",
      AWAITING_APPROVAL: "pending",
      OFFERED: "info",
      HELD: "warning",
      CLAIMED: "brand",
      FUNDED: "brand",
      DELIVERED: "brand",
      REPAID_WITHIN_WINDOW: "success",
      REPAID_LATE: "warning",
      DEFAULTED_WITH_LATE_CHARGE: "danger",
      REFUND_DUE: "danger",
      CLOSED_BY_CLAIM: "neutral",
      EXPIRED: "neutral",
      CANCELLED: "neutral",
    });
  });
});
