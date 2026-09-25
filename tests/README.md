# Verification

The app is still a standalone `index.html`; no runtime or build dependencies were added.

- `ui.cjs` uses an externally available Playwright installation. Run `node tests/ui.cjs` with Playwright on `NODE_PATH` if it is not installed locally. Optionally set `CHROMIUM_PATH` to a compatible Chromium executable. All network calls are mocked; no real accounts or trades are changed. It covers the desktop sidebar, category rows, carousel ranking/navigation, closing order, account menu/session persistence, settings, confirmed account deletion, search/tabs, 390/760/1024px layouts, empty states, whole-unit stake buttons, clickable cards, early-resolution UI, and a one-point odds line.
- `account-deletion.sql` runs in a transaction against an **isolated** database with the existing OfficeBets schema and the new migration installed. It creates its own fixture badges and markets, then rolls them back. It covers admin-only deletion, self-deletion protection, typed-name confirmation, retry idempotency, deleted-badge rejection, unchanged prices/collateral/other wallets, volume retention, permanent first-trade edit locking, early admin settlement of another creator's market, and remaining players' payouts.

The SQL checks were run with PGlite using a schema-only copy of the connected database (constraints, indexes, functions and triggers), followed by the new migration. The browser checks passed in headless Chromium. Desktop and phone screenshots were visually reviewed. JavaScript syntax and `git diff --check` passed.

## Database rollout

Applied to OfficeBets Supabase with explicit user approval on 2026-09-24. The committed filename `supabase/migrations/20260924062752_officebets_discovery_account_deletion.sql` matches the live migration-history version. Its SQL is unchanged from the tested migration. It is compatible with the currently deployed v10 page. No accounts were deleted; before/after counts and wallet totals were unchanged. Live snapshot/market-view calls, volume fields, first-trade flags, RLS and direct-table restrictions were verified. Security advisors show the same intentional badge-RPC warnings and private-table policy notices; performance advisors reported only unused-index information. The website has not been merged or deployed.

The migration adds `markets.ever_traded` and extends the existing validated RPCs. RLS and direct-table restrictions remain intact. Existing security-advisor notices concern the intentional public honor-system RPCs and private tables without policies; this change does not replace badge access with authenticated identities.

An organizer's confirmed deletion removes the badge, positions, comments and request receipts; its available GW returns to the house. Predictions transfer to the organizer. Other positions, prices, collateral, price history and financial audit entries remain. Deleted participants display as “Former teammate” in trade history. Audit descriptions may still contain historical names; this is account removal, not erasure of all historical mentions. Self-deletion is blocked so the organizer remains available for retry receipts.

Volume is total absolute BUY + SELL value over the full market-linked ledger, including trades by removed accounts. Tracking starts with v10; earlier entries without a market ID cannot be reliably attributed. The carousel includes the five highest-volume unresolved predictions, with deterministic tie ordering. Ending soon lists the next five open predictions. A one-point odds line represents one observed quote, not fabricated past trades; when history has not arrived yet, the chart labels its current-odds preview.

## Approved dashboard and verified-admin changes (2026-09-25)

New checks:

- `redesign.cjs`: deterministic mocked browser checks for auto/manual hero rotation,
  pause/play/focus/reduced motion, minimal-history timelines, edge scroll controls,
  preserved shelf scroll position, admin-only overflow and confirmation, profile/role
  forms, retained buy/transfer/boost requests, and 1440/1024/760/390px layouts.
- `admin-permissions.cjs`: isolated PGlite tests using `fixtures/schema-before-design.sql`
  (schema only, no live rows) plus the two new migrations. Covers forged admin badge IDs,
  ordinary-role requests, verified edits, first-trade locks, early resolution, deletion,
  grant/revoke, idempotency, last-admin safeguards, revoked Auth sessions and direct table
  restrictions. Also runs the updated account-deletion regression SQL.

Run using locally available Playwright and PGlite; no runtime application dependencies or
build system have been added. Example with dependencies installed outside the repository:

```sh
NODE_PATH=/path/to/test/node_modules CHROMIUM_PATH=/path/to/chromium node tests/ui.cjs
NODE_PATH=/path/to/test/node_modules CHROMIUM_PATH=/path/to/chromium node tests/redesign.cjs
NODE_PATH=/path/to/test/node_modules node tests/admin-permissions.cjs
```

Test versions used: Playwright from the Codex runtime, Chromium 138 via
`@sparticuz/chromium@138.0.2`, and `@electric-sql/pglite@0.3.14`. Browser tests mock all
backend/Auth responses; SQL tests verify actual PostgreSQL permission logic using test
Auth tables/session claims. They do not substitute for first-admin hosted Auth sign-in
verification during rollout. No live financial or destructive test operations were run.

Identity preparation was applied to OfficeBets as migration `20260925070548`.
It created an empty private mapping table, helper and status RPC. Verification confirmed
RLS, no anon/authenticated table grants, no anonymous status-RPC grant, no role changes,
and unchanged counts (11 members, 11 markets) and combined wallet value (7096.0226959953 GW).
The protected-actions migration is **not applied**: the owner must first link a confirmed
Auth identity. See `docs/admin-rollout.md`; do not merge/release blindly before that cutover.

Security advisors retain the intentional public badge-RPC warnings. Identity preparation
adds the expected informational “RLS enabled, no policy” finding for the private mapping
and the authenticated-definer finding for the narrowly scoped admin status RPC. No public
table access was added. References:
[private RLS tables](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy),
[anonymous definer RPCs](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable),
[authenticated definer RPCs](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).
