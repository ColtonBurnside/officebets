# Verification

The app is still a standalone `index.html`; no runtime or build dependencies were added.

- `ui.cjs` uses an externally available Playwright installation. Run `node tests/ui.cjs` with Playwright on `NODE_PATH` if it is not installed locally. Optionally set `CHROMIUM_PATH` to a compatible Chromium executable. All network calls are mocked; no real accounts or trades are changed. It covers the desktop sidebar, category rows, carousel ranking/navigation, closing order, account menu/session persistence, settings, confirmed account deletion, search/tabs, 390/760/1024px layouts, empty states, whole-unit stake buttons, clickable cards, early-resolution UI, and a one-point odds line.
- `account-deletion.sql` runs in a transaction against an **isolated** database with the existing OfficeBets schema and the new migration installed. It creates its own fixture badges and markets, then rolls them back. It covers admin-only deletion, self-deletion protection, typed-name confirmation, retry idempotency, deleted-badge rejection, unchanged prices/collateral/other wallets, volume retention, permanent first-trade edit locking, early admin settlement of another creator's market, and remaining players' payouts.

The SQL checks were run with PGlite using a schema-only copy of the connected database (constraints, indexes, functions and triggers), followed by the new migration. The browser checks passed in headless Chromium. Desktop and phone screenshots were visually reviewed. JavaScript syntax and `git diff --check` passed.

## Database rollout

Apply `supabase/migrations/20260924025902_officebets_discovery_account_deletion.sql` before merging the UI. It is compatible with the currently deployed v10 page. **It has not been applied to production:** automatic approval review blocked the live migration pending explicit user approval of production changes. No production accounts were deleted.

The migration adds `markets.ever_traded` and extends the existing validated RPCs. RLS and direct-table restrictions remain intact. Existing security-advisor notices concern the intentional public honor-system RPCs and private tables without policies; this change does not replace badge access with authenticated identities.

An organizer's confirmed deletion removes the badge, positions, comments and request receipts; its available GW returns to the house. Predictions transfer to the organizer. Other positions, prices, collateral, price history and financial audit entries remain. Deleted participants display as “Former teammate” in trade history. Audit descriptions may still contain historical names; this is account removal, not erasure of all historical mentions. Self-deletion is blocked so the organizer remains available for retry receipts.

Volume is total absolute BUY + SELL value over the full market-linked ledger, including trades by removed accounts. Tracking starts with v10; earlier entries without a market ID cannot be reliably attributed. The carousel includes the five highest-volume unresolved predictions, with deterministic tie ordering. Ending soon lists the next five open predictions. A one-point odds line represents one observed quote, not fabricated past trades; when history has not arrived yet, the chart labels its current-odds preview.
