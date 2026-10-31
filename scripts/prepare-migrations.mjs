import { mkdir, readFile, writeFile } from "node:fs/promises";
const source = [
  // Keep historical migrations unchanged; append community safety repairs.
  ["202610260001_baseline.sql", "supabase_schema.sql"],
  ["202610260002_community.sql", "migrations/002_customer_platform.sql"],
  ["202610260003_billing.sql", "migrations/003_billing_streams.sql"],
  ["202610260004_operations.sql", "migrations/004_catalog_and_operations.sql"],
  ["202610310005_community_safety.sql", "migrations/005_community_safety.sql"],
];
await mkdir("supabase/migrations", { recursive: true });
for (const [output, input] of source) {
  await writeFile("supabase/migrations/" + output, await readFile(input));
}
console.log(
  "Prepared ordered Supabase CLI migration files. No database connection or database changes were made.",
);
