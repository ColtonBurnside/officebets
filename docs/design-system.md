# OfficeBets visual system

Implemented target: the approved second dashboard concept, with larger probabilities.
**High content density, low interface density.** Preserve exploration: a large featured
market, horizontal market shelves with a partially visible next card, multiple vertical
sections, and a right-side account/context area. Do not replace this with a directory or table.

## Tokens and type

The final inline `:root` block in `index.html` owns `--ob-*` tokens. Keep the existing
single-file deployment; new UI should use these tokens and the shared rendering helpers.

| Purpose | Value / rule |
| --- | --- |
| Canvas / surface / raised / inset | `#0D1117` / `#161E28` / `#1A2532` / `#0B1017` |
| Border / primary text / secondary text | `#2B3A4C` / `#F2F4F8` / `#B7C3D2` |
| Primary cyan | **`#00F2FE`**: leading probability, energy, position, active channel, timeline and keyboard focus. Inactive categories, icons and borders stay neutral. |
| Creation CTA | `#EF4444`, dark label; hover `#FF6868`. One primary New Prediction action. No glow. |
| Destruction | Quiet `#FF9393` text; danger background `#351C24` only where useful. Separate from routine actions; confirmation required. Never use red for NO odds. |
| Resolved result | `#63DFAE` plus a check and winning outcome, not color alone. |
| Headings / body / numerical data | Gotham Medium / Gotham Book / JetBrains Mono; system and monospace fallbacks. Font files are not in the repository, so no unlicensed font downloads or claims of exact font fidelity. |
| Card title / numerical scale | 18px / 1.35; paired card odds 40px desktop, 36px mobile; hero odds 36–54px. Tabular numerical figures. |
| Spacing | 4 / 8 / 12 / 16 / 20 / 24 / 32px. 16px shelf gap, 20px card padding, 24px major gap. |
| Geometry | 6px controls, 8px filters, 10px cards, 12px hero; round avatars. Avoid one radius everywhere. |

## Surfaces and market objects

One outer market surface signifies one navigable object. Group internal data through
alignment, type and proximity. No miniature YES/NO cards, repeated Trade/View buttons,
volume/collateral labels, or descriptions on browsing cards. Keep those needed for actual
trading or evaluation in the full prediction view.

Card hierarchy: category and creator → question → probability/outcomes → close state/time
and the viewer's position, if any. Binary markets use paired large numerals and one shared
rail. Multi-outcome markets preview the two leading outcomes plus the remaining count;
the full trading view retains all outcomes. Resolved cards show the winner, not redundant
live probability rails. `probabilityMarkup`, `creatorMarkup`, `closeLabel`, and
`positionSummary` are shared between hero/cards. Clicking the card opens prediction detail;
creator links and admin controls are independent targets. Enter/Space on the focused card
also opens detail.

The account sidebar preserves avatar, name, role, bio, energy and estimated position value.
There is no sidebar Edit Profile button. Editing one's profile remains in the top account
menu. Supercharge, Send GW and the account selector stay in global navigation. Existing
search, portfolio, leaderboard, settings and audit access are retained.

## Featured hero

Retain existing top-five ranking internally; display no volume. An eight-second timer
rotates markets, with previous/next, pagination, count and Pause/Play controls. Pointer
interaction, focus and manual navigation pause until explicit Play. Hover temporarily
suspends rotation. Hidden tabs, non-market views and open dialogs suspend the timer.
Reduced-motion preference starts paused. A single market disables rotation controls;
empty collections show an explicit empty state. Live updates preserve the selected market
while it remains eligible. Never rotate away from someone reading or trading a market.

History uses `ob_market_view`, cached per market and revision with stale-response protection.
Binary hero charts display the first outcome; detail retains all series. Multi-outcome hero
charts display all series using the existing chart palette. No history: label a current-odds
reference. One observation: a flat reference labeled as one recorded quote. Fetch failure:
label history unavailable. Never fabricate prior trades. The entire hero opens detail;
carousel and profile/admin controls do not trigger navigation.

## Horizontal shelves

Each shelf is a native horizontal scroller with proximity snap, preserving scroll positions
across renders. Desktop card width intentionally leaves part of the next card visible.
Full-height edge controls fade into the row, with centered chevrons, larger hover/focus
presence and accessible names. Hide unavailable edges at either end. ResizeObserver and
scroll events update edge availability. Touch/native scrolling always remains available;
reduced motion disables smooth scrolling. Edge buttons scroll approximately one card.

## Admin hierarchy

Verified admins see a discreet `•••` overflow on cards/hero and in detail. It contains
Edit prediction (or a clear locked state), Resolve early/Resolve, and separated Delete
prediction. The overlay escapes the shelf's overflow clipping; Escape returns focus,
arrow keys navigate actions, and outside click/scroll closes it. Creator permissions remain
accessible in detail without adding admin-looking controls to ordinary browsing cards.
Existing resolution and deletion confirmations are retained. Editing is still locked after
the first trade or resolution.

Clicking a creator opens a profile; verified admins can edit other profiles there. Settings
provides profile and role management. Role changes require an explicit named confirmation;
self-revocation is unavailable and the backend prevents losing the last verified admin.
Badge selection is not admin authentication. See `admin-rollout.md` for the verified Auth
identity boundary and deployment prerequisite.

## Responsive and interaction rules

Above 1100px: main content plus 290px context rail, hero odds beside timeline. At intermediate
widths: 250px rail, vertically stacked hero content, wider shelf cards. At 760px and below:
stack creation, hero, account, channels, market shelves and ending-soon content; preserve
horizontal shelves at roughly 78% card width. Top actions wrap. Modal and form content must
fit the viewport; existing mobile trade detail reflow remains. Do not scale the desktop
layout down or turn shelves into tables. Focus uses a 2px cyan outline. Hover only changes
surface/border, without lift. Honor reduced motion; no pulsing or decorative glow.
