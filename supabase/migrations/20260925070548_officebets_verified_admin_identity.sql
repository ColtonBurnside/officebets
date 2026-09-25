-- Additive preparation only: no role changes and no existing RPC behavior changes.
-- Link the first confirmed Auth identity using docs/admin-rollout.md before cutover.
begin;
create table officebets.admin_identities (
 member_id uuid primary key references officebets.members(id) on delete cascade,
 auth_user_id uuid not null unique references auth.users(id) on delete restrict,
 created_at timestamptz not null default clock_timestamp()
);
alter table officebets.admin_identities enable row level security;
revoke all on officebets.admin_identities from public,anon,authenticated;

-- Private helper; runs inside the existing definer RPC boundary. No direct API access.
create or replace function officebets.verified_admin(p_member uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(
   select 1 from officebets.admin_identities i
   join officebets.members m on m.id=i.member_id
   join auth.users u on u.id=i.auth_user_id
   where m.id=p_member and m.active and m.is_admin and i.auth_user_id=auth.uid()
     and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now())
     and exists(select 1 from auth.sessions s where s.user_id=u.id
       and s.id::text=(auth.jwt()->>'session_id'))
 )
$$;
revoke all on function officebets.verified_admin(uuid) from public,anon,authenticated;

-- Returns only the requesting identity's current authority, never the identity directory.
create or replace function public.ob_admin_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('memberId',(
   select i.member_id from officebets.admin_identities i
   where auth.uid() is not null and i.auth_user_id=auth.uid()
     and officebets.verified_admin(i.member_id)
 ))
$$;
revoke all on function public.ob_admin_status() from public,anon;
grant execute on function public.ob_admin_status() to authenticated;
notify pgrst,'reload schema';
commit;
