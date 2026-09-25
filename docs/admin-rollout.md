# Verified admin rollout

## Why a linked identity is required

OfficeBets deliberately uses public selectable badges for ordinary play. Before this change,
`ob_action(p_user,...)` trusted that submitted badge's `is_admin` value. Anyone could supply
an admin badge ID. Merely adding more role checks would not meet the requirement to prevent
ordinary client requests from granting or exercising admin authority.

This change retains `officebets.members.is_admin` as the sole role source. A private
`officebets.admin_identities` table links an admin badge to a confirmed Supabase Auth user.
Every privileged request checks `auth.uid()`, that link, the current active/admin flags,
confirmed email, ban status and a still-existing Auth session ID. User-editable JWT metadata
never grants authority. Revocation is checked before idempotency receipts, so a stale JWT
or replay cannot regain access. Public badge browsing, trading, boosting and transfers retain
the existing honor-system behavior; this is not a full authentication migration for all users.

Admin profile editing also requires verified sign-in. Ordinary users keep own-profile and
creator actions under the existing badge model. Non-admin badge impersonation remains an
intentional limitation of that model, not a security guarantee introduced by this PR.

## Two migrations; do not blindly apply both

1. `*_officebets_verified_admin_identity.sql` is additive preparation. It creates the private,
   RLS-enabled identity mapping/helper and the read-only `ob_admin_status` endpoint. Existing
   actions remain unchanged. No identity or role is assigned automatically.
2. `*_officebets_verified_admin_actions.sql` is the security cutover. It updates the existing
   action RPC for verified admin authority, profile fields, any-creator editing under the
   existing first-trade lock, and grant/revoke. It adds a last-admin trigger and explicitly
   refuses installation unless a confirmed first admin is linked.

The second migration changes old unauthenticated organizer behavior and must be coordinated
with this PR's UI. It must not be applied early and leave the owner without admin access.
No website merge/deployment is performed by this task.

## Bootstrap the first admin (trusted operator only)

Create/confirm the intended owner's Supabase Auth account using the project's Auth interface,
or register using the new Admin sign-in form and confirm the email. Verify the exact email
with the owner; do not infer it from a display name. Registration alone never assigns a role.
Use the project's actual application URL in Supabase's allowed redirect URLs if registration
email confirmation will redirect to this app. Password sign-in itself needs no redirect.
Never put service-role keys, passwords or admin bypass tokens into the frontend.

After identity preparation is installed, a trusted SQL operator can bind the confirmed owner.
Replace both placeholder values only after verifying them; this script cannot be called by
a browser/API role. Do not paste passwords into SQL or source control.

```sql
begin;
do $$
declare
  badge uuid := 'REPLACE_WITH_EXISTING_ADMIN_BADGE_UUID';
  confirmed_email text := 'REPLACE_WITH_OWNER_CONFIRMED_EMAIL';
  auth_id uuid;
begin
  perform 1 from officebets.revision where id=1 for update;
  if not exists(select 1 from officebets.members where id=badge and active and is_admin) then
    raise exception 'Choose the existing active admin badge';
  end if;
  select id into auth_id from auth.users where lower(email)=lower(confirmed_email)
    and email_confirmed_at is not null and (banned_until is null or banned_until<=now());
  if auth_id is null then raise exception 'Confirmed owner sign-in account not found'; end if;
  insert into officebets.admin_identities(member_id,auth_user_id) values(badge,auth_id);
end $$;
commit;
```

Then test the owner's sign-in and `ob_admin_status`, apply the actions migration, and release
this UI in the same controlled rollout. Confirm an unauthenticated admin mutation returns
42501, the linked admin can manage a test target, and badge trading still works. Do not test
live deletion, payouts or role revocation on real users as part of a smoke test.

## Subsequent admins

A teammate registers a sign-in account and confirms their email. A verified admin opens
Settings → teammate Edit profile → Admin access, enters that confirmed email, and explicitly
confirms Grant admin status. The same panel revokes another admin with confirmation.
Identity bindings are one-to-one; changing a binding requires revocation first. Self-role
changes are blocked. Last-admin protection considers other active, confirmed, linked admins
and uses the existing revision-row transaction lock. Auth identity deletion is restricted
while a mapping exists; trusted recovery must first establish another working admin.

The Auth session is stored in `sessionStorage` for tab-scoped persistence; badge selection
continues in its existing local-storage key. Badge Out signs out admin access too. Password
reset and first-admin account recovery remain in the project's existing Auth administration;
no custom password storage is introduced. The UI must never be the authorization boundary.

## Data and compatibility

No existing profiles, balances, markets, positions or prices are rewritten by the migrations.
Profile administration supports existing name, avatar, bio and balance fields. Role changes
are audited. Deletion retains the existing refund/account cleanup behavior. Only untouched,
unresolved predictions can be edited; administrators do not rewrite already-traded terms.
Private tables/sequences remain inaccessible to `anon` and `authenticated`; no broad RLS or
schema grants are added. Schema-only, isolated Postgres tests are in `tests/admin-permissions.cjs`.
