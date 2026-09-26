-- Durable market closure, compensating resolution entries, server-earned icons and recurring templates.
begin;
alter table officebets.markets add column closed_permanently boolean not null default false;
alter table officebets.markets add column closed_at timestamptz;
alter table officebets.markets add column opens_at timestamptz;
alter table officebets.members drop constraint members_balance_check;
alter table officebets.members add constraint members_balance_check check(balance<=1000000000000);

create table officebets.member_achievements(
 member_id uuid not null references officebets.members(id) on delete cascade,
 achievement text not null check(achievement in ('loan_shark','master_better','biggest_loser','how_did_we_get_here')),
 unlocked_at timestamptz not null default clock_timestamp(),
 primary key(member_id,achievement)
);
alter table officebets.member_achievements enable row level security;
revoke all on officebets.member_achievements from public,anon,authenticated;

create table officebets.persistent_bets(
 id uuid primary key default gen_random_uuid(), creator uuid not null references officebets.members(id),
 title text not null check(length(btrim(title)) between 1 and 180),
 description text not null default '' check(length(description)<=2000),
 category text not null references officebets.categories(id),
 names text[] not null check(cardinality(names) between 2 and 8),
 cadence text not null check(cadence in ('daily','weekly')),
 close_time time with time zone not null,
 close_weekday integer check(close_weekday between 0 and 6),
 next_open_at timestamptz not null, active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(), retired_at timestamptz,
 check((cadence='daily' and close_weekday is null) or (cadence='weekly' and close_weekday is not null))
);
alter table officebets.persistent_bets enable row level security;
revoke all on officebets.persistent_bets from public,anon,authenticated;
alter table officebets.markets add column persistent_bet_id uuid references officebets.persistent_bets(id);
create unique index persistent_instance_slot on officebets.markets(persistent_bet_id,opens_at) where persistent_bet_id is not null;
create index persistent_instance_history on officebets.markets(persistent_bet_id,created_at desc);

create table officebets.resolutions(
 id uuid primary key default gen_random_uuid(),market_id uuid not null,
 resolved_by uuid,outcome integer not null,
 vault_before numeric(30,12) not null,resolved_at timestamptz not null default clock_timestamp(),
 reversed_at timestamptz,reversed_by uuid
);
create unique index one_active_resolution on officebets.resolutions(market_id) where reversed_at is null;
alter table officebets.resolutions enable row level security;
revoke all on officebets.resolutions from public,anon,authenticated;
alter table officebets.ledger add column resolution_id uuid references officebets.resolutions(id);
alter table officebets.ledger add column reverses_ledger_id bigint references officebets.ledger(id);
create unique index one_reversal_per_entry on officebets.ledger(reverses_ledger_id) where reverses_ledger_id is not null;
create table officebets.resolution_entry_links(
 resolution_id uuid not null references officebets.resolutions(id),
 ledger_id bigint not null unique references officebets.ledger(id),
 primary key(resolution_id,ledger_id)
);
alter table officebets.resolution_entry_links enable row level security;
revoke all on officebets.resolution_entry_links from public,anon,authenticated;
-- Preserve every historical ledger row. Link legacy market-tagged settlements separately.
insert into officebets.resolutions(market_id,resolved_by,outcome,vault_before,resolved_at)
 select m.id,(select q.user_id from officebets.requests q where q.action='settle'
   and q.payload->>'market'=m.id::text order by q.at desc limit 1),m.winner,sum(l.amount),max(l.at)
 from officebets.markets m join officebets.ledger l on l.market_id=m.id
   and l.kind in ('SETTLEMENT','HOUSE_RETURN')
 where m.winner is not null group by m.id
 having count(*) filter(where l.kind='HOUSE_RETURN')=1;
insert into officebets.resolution_entry_links(resolution_id,ledger_id)
 select r.id,l.id from officebets.resolutions r join officebets.ledger l on l.market_id=r.market_id
   and l.kind in ('SETTLEMENT','HOUSE_RETURN') where l.resolution_id is null;

create or replace function officebets.avatar_allowed(p_member uuid,p_avatar text) returns boolean
language sql stable set search_path='' as $$
 select case p_avatar when '🦈' then 'loan_shark' when '🎰' then 'master_better'
   when '💀' then 'biggest_loser' when '⁉️' then 'how_did_we_get_here' else null end is null
 or exists(select 1 from officebets.member_achievements a where a.member_id=p_member and a.achievement=
   case p_avatar when '🦈' then 'loan_shark' when '🎰' then 'master_better'
   when '💀' then 'biggest_loser' when '⁉️' then 'how_did_we_get_here' end)
$$;
revoke all on function officebets.avatar_allowed(uuid,text) from public,anon,authenticated;

create or replace function officebets.unlock_zero_net_worth(p_member uuid) returns void
language plpgsql set search_path='' as $$
declare worth numeric;
begin
 select u.balance+coalesce(sum(case when m.winner is not null then 0
   else p.shares*((1/m.reserves[p.outcome+1])/(select sum(1/v) from unnest(m.reserves) v)) end),0)
 into worth from officebets.members u left join officebets.positions p on p.user_id=u.id and p.shares>0
 left join officebets.markets m on m.id=p.market_id where u.id=p_member group by u.balance;
 if worth=0 then insert into officebets.member_achievements(member_id,achievement)
   values(p_member,'biggest_loser') on conflict do nothing; end if;
end $$;
revoke all on function officebets.unlock_zero_net_worth(uuid) from public,anon,authenticated;

-- Existing durable trades and resolved positions also qualify; unlocks never relock.
insert into officebets.member_achievements(member_id,achievement)
 select user_id,'loan_shark' from officebets.ledger where kind='TRANSFER_SENT' and user_id is not null
 group by user_id having sum(-amount)>1000 on conflict do nothing;
insert into officebets.member_achievements(member_id,achievement)
 select distinct p.user_id,'master_better' from officebets.positions p
 join officebets.markets m on m.id=p.market_id and m.winner=p.outcome
 join officebets.ledger l on l.market_id=m.id and l.user_id=p.user_id and l.kind='SETTLEMENT'
 where p.cost>0 and l.amount>=20*p.cost on conflict do nothing;
insert into officebets.member_achievements(member_id,achievement)
 select distinct user_id,'how_did_we_get_here' from officebets.ledger
 where kind='BUY' and user_id is not null and extract(dow from at at time zone 'UTC') in (0,6)
 on conflict do nothing;
do $$ declare member_id uuid; begin for member_id in select id from officebets.members loop
 perform officebets.unlock_zero_net_worth(member_id); end loop; end $$;

-- Each slot is advanced under the same serialized revision lock used by trades.
-- Missed closed slots are skipped; no retroactive open betting or duplicate funded markets.
create or replace function officebets.process_persistent_bets(p_now timestamptz default clock_timestamp()) returns integer
language plpgsql security definer set search_path='' as $$
declare d officebets.persistent_bets; slot timestamptz; close_at timestamptz;
  local_open timestamp; days_to_close integer; created_count integer:=0; new_market uuid;
begin
 perform 1 from officebets.revision where id=1 for update;
 for d in select * from officebets.persistent_bets where active order by id loop
   slot:=d.next_open_at;
   while slot<=p_now loop
     local_open:=slot at time zone 'UTC';
     if d.cadence='daily' then
       close_at:=((local_open::date+d.close_time::time) at time zone 'UTC');
     else
       days_to_close:=(d.close_weekday-extract(dow from local_open)::integer+7)%7;
       close_at:=((local_open::date+days_to_close+d.close_time::time) at time zone 'UTC');
       if close_at<=slot then close_at:=close_at+interval '7 days'; end if;
     end if;
     if close_at>p_now then
       insert into officebets.markets(creator,title,description,category,closes_at,names,reserves,opens_at,persistent_bet_id)
       values(d.creator,d.title,d.description,d.category,close_at,d.names,
         array_fill(200::numeric,array[cardinality(d.names)]),slot,d.id)
       on conflict do nothing returning id into new_market;
       if new_market is not null then
         perform set_config('officebets.market_id',new_market::text,true);
         update officebets.house set granted=granted+200 where id=1;
         perform officebets.log_entry(null,'HOUSE_SEED',-200,'House-funded recurring liquidity: '||d.title);
         perform officebets.log_entry(d.creator,'MARKET_MINT',0,'Recurring instance: '||d.title);
         created_count:=created_count+1;
       end if;
     end if;
     slot:=((close_at at time zone 'UTC')::date+1+time '07:00') at time zone 'UTC';
     if d.cadence='daily' then slot:=((local_open::date+1+time '07:00') at time zone 'UTC'); end if;
   end loop;
   if slot<>d.next_open_at then update officebets.persistent_bets set next_open_at=slot where id=d.id; end if;
 end loop;
 if created_count>0 then update officebets.revision set value=value+1 where id=1; end if;
 return created_count;
end $$;
revoke all on function officebets.process_persistent_bets(timestamptz) from public,anon,authenticated;

create or replace function public.ob_snapshot() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 -- One statement gives all collections the same MVCC snapshot.
 select jsonb_build_object(
 'house',(select jsonb_build_object('granted',granted,'returned',returned) from officebets.house where id=1),
 'revision',(select value from officebets.revision where id=1), 'serverTime',clock_timestamp(),
 'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by name),'[]') from officebets.categories),
 'users',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'balance',u.balance,'balanceExact',u.balance::text,'avatar',u.avatar,'bio',u.bio,'isAdmin',u.is_admin,'active',u.active,
   'tag',case when u.is_admin then 'Organizer' else 'Teammate' end,
   'lastSuperchargedAt',extract(epoch from u.last_boost)*1000,
   'achievements',(select coalesce(jsonb_agg(a.achievement order by a.achievement),'[]') from officebets.member_achievements a where a.member_id=u.id),
   'slips',(select coalesce(jsonb_agg(jsonb_build_object('id',p.market_id::text||':'||p.outcome,'marketId',p.market_id,
     'outcomeIdx',p.outcome,'shares',p.shares,'sharesExact',p.shares::text,'wager',p.cost,'entryPrice',case when p.shares>0 then p.cost/p.shares else 0 end,
     'settled',m.winner is not null,'payoutReceived',case when m.winner=p.outcome then p.shares else 0 end) order by m.created_at desc),'[]')
     from officebets.positions p join officebets.markets m on m.id=p.market_id where p.user_id=u.id and p.shares>0)
   ) order by u.name),'[]') from officebets.members u),
 'markets',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'creatorId',m.creator,'title',m.title,'description',m.description,
   'categoryId',m.category,'createdAt',m.created_at,'closesAt',m.closes_at,'resolved',m.winner is not null,'winningOutcomeIdx',m.winner,
   'everTraded',m.ever_traded,'closedPermanently',m.closed_permanently,'closedAt',m.closed_at,
   'persistentBetId',m.persistent_bet_id,'opensAt',m.opens_at,
   'volume',coalesce((select sum(abs(l.amount)) from officebets.ledger l where l.market_id=m.id and l.kind in ('BUY','SELL')),0),
   'collateralVault',m.vault,'outcomes',(select jsonb_agg(jsonb_build_object('name',m.names[i],'poolReserve',m.reserves[i]) order by i)
     from generate_subscripts(m.names,1) i)) order by m.created_at desc),'[]') from officebets.markets m),
 'persistentBets',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'description',d.description,
   'categoryId',d.category,'outcomes',d.names,'cadence',d.cadence,'closeTime',d.close_time,'weekday',d.close_weekday,
   'active',d.active,'nextOpenAt',d.next_open_at) order by d.created_at),'[]') from officebets.persistent_bets d where d.active),
 'transactions',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'timestamp',l.at,'userId',l.user_id,'userName',coalesce(u.name,case when l.kind in ('HOUSE_SEED','HOUSE_RETURN') then 'House' else 'Former teammate' end),
   'type',l.kind,'amount',l.amount,'details',l.details) order by l.id desc),'[]')
   from (select * from officebets.ledger order by id desc limit 500) l left join officebets.members u on u.id=l.user_id)
 ) into result;
 return result;
end $$;

CREATE OR REPLACE FUNCTION public.ob_action(p_request uuid, p_user uuid, p_action text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_variable
declare
 uid uuid:=p_user; actor officebets.members; m officebets.markets; prior officebets.requests;
 a numeric; out_amount numeric; min_out numeric; held numeric; old_cost numeric; residual numeric;
 r numeric[]; n integer; idx integer; i integer; k numeric; lo numeric; hi numeric; mid numeric; test_k numeric;
 title text; descr text; cat text; names text[]; deadline timestamptz; recipient uuid; memo text; row_p record; identity_id uuid; grant_role boolean; resolution uuid; original_entry record; recurrence officebets.persistent_bets; weekday integer; opening time with time zone;
begin
 perform set_config('officebets.market_id','',true);
 -- Serializes tiny-team mutations; wallets, positions, ledger and receipts commit together.
 perform 1 from officebets.revision where id=1 for update;
 select * into actor from officebets.members where id=uid and active;
 if not found then raise exception using errcode='42501',message='Choose an active teammate badge first.'; end if;
 if p_request is null or p_action is null or p_args is null or jsonb_typeof(p_args)<>'object' or octet_length(p_args::text)>16000 then
   raise exception 'Invalid request'; end if;
 -- Authorization is checked before receipt replay as well as every new mutation.
 -- Ordinary badge trading stays unchanged. Privileged requests cannot impersonate an admin badge.
 if p_action in ('admin_user','delete_user','admin_role','reverse_resolution','create_persistent','edit_persistent','delete_persistent') or
    (actor.is_admin and p_action in ('profile','edit_market','delete_market','settle','close_market')) then
   if not officebets.verified_admin(uid) then
     raise exception using errcode='42501',message='Verified admin sign-in required.';
   end if;
 end if;
 if p_action='profile' and (p_args ? 'isAdmin' or p_args ? 'is_admin' or p_args ? 'role') then
   raise exception using errcode='42501',message='Profile editing cannot change admin access';
 end if;
 select * into prior from officebets.requests where user_id=uid and request_id=p_request;
 if found then
   if prior.action<>p_action or prior.payload<>p_args then raise exception 'Request ID reused for a different action'; end if;
   return public.ob_snapshot();
 end if;

 if p_action='boost' then
   if actor.last_boost is not null and clock_timestamp()<actor.last_boost+interval '24 hours' then raise exception 'Daily boost is still recharging'; end if;
   update officebets.members set balance=balance+250,last_boost=clock_timestamp() where id=uid;
   perform officebets.log_entry(uid,'BOOST',250,'Daily supercharge');
 elsif p_action='transfer' then
   a:=(p_args->>'amount')::numeric; recipient:=(p_args->>'recipient')::uuid; memo:=btrim(p_args->>'memo');
   if a is null or not(a between 0.01 and 1000000) or a<>trunc(a,2) or a>actor.balance then raise exception 'Enter an affordable amount with at most two decimals'; end if;
   if recipient is null or recipient=uid or not exists(select 1 from officebets.members where id=recipient and active) then raise exception 'Invalid recipient'; end if;
   if memo is null or length(memo) not between 1 and 120 then raise exception 'A note of 1–120 characters is required'; end if;
   update officebets.members set balance=balance-a where id=uid;
   update officebets.members set balance=balance+a where id=recipient;
   perform officebets.log_entry(uid,'TRANSFER_SENT',-a,'To '||(select name from officebets.members where id=recipient)||': '||memo);
   perform officebets.log_entry(recipient,'TRANSFER_RECV',a,'From '||actor.name||': '||memo);
   perform officebets.unlock_zero_net_worth(recipient);
   if (select coalesce(sum(-amount),0) from officebets.ledger where user_id=uid and kind='TRANSFER_SENT')>1000 then
     insert into officebets.member_achievements(member_id,achievement) values(uid,'loan_shark') on conflict do nothing;
   end if;
 elsif p_action='admin_role' then
   recipient:=(p_args->>'user')::uuid; grant_role:=(p_args->>'grant')::boolean;
   if recipient is null or recipient=uid or grant_role is null then raise exception 'Choose another teammate and an explicit role change'; end if;
   select name into title from officebets.members where id=recipient and active;
   if not found then raise exception 'Choose an active teammate'; end if;
   if (p_args->>'confirmName') is distinct from title then raise exception 'Badge name changed; confirm again'; end if;
   if grant_role then
     select id into identity_id from auth.users where lower(email)=lower(btrim(p_args->>'email'))
       and email_confirmed_at is not null and (banned_until is null or banned_until<=now());
     if identity_id is null then raise exception 'That sign-in account must register and confirm its email first'; end if;
     if exists(select 1 from officebets.admin_identities where auth_user_id=identity_id and member_id<>recipient) then raise exception 'This sign-in account is already linked to another badge'; end if;
     if exists(select 1 from officebets.admin_identities where member_id=recipient and auth_user_id<>identity_id) then raise exception 'This badge is linked to another identity; revoke access before changing its identity'; end if;
     insert into officebets.admin_identities(member_id,auth_user_id) values(recipient,identity_id) on conflict(member_id) do nothing;
     update officebets.members set is_admin=true where id=recipient;
   else
     update officebets.members set is_admin=false where id=recipient;
     delete from officebets.admin_identities where member_id=recipient;
   end if;
   perform officebets.log_entry(uid,'ADMIN_ROLE',0,case when grant_role then 'Granted' else 'Revoked' end||' admin access for '||title);
 elsif p_action in ('profile','admin_user') then
   recipient:=case when p_action='profile' then uid else (p_args->>'user')::uuid end;
   if p_action='admin_user' and not actor.is_admin then raise exception using errcode='42501',message='Only an organizer can manage users'; end if;
   if not exists(select 1 from officebets.members where id=recipient) then raise exception 'Unknown badge'; end if;
   title:=btrim(p_args->>'name');
   if title is null or length(title) not between 1 and 40 then raise exception 'Use a name of 1–40 characters'; end if;
   if exists(select 1 from officebets.members where id<>recipient and lower(name)=lower(title)) then raise exception 'That badge name is already taken'; end if;
   if p_action='profile' then
     descr:=coalesce(btrim(p_args->>'bio'),''); memo:=btrim(p_args->>'avatar');
     if length(descr)>120 or memo is null or length(memo) not between 1 and 16 then raise exception 'Use a short avatar and a bio of at most 120 characters'; end if;
     if not officebets.avatar_allowed(uid,memo) then raise exception 'This profile icon is locked'; end if;
     update officebets.members set name=title,avatar=memo,bio=descr where id=uid;
     perform officebets.log_entry(uid,'PROFILE',0,'Updated badge profile');
   else
     select balance into old_cost from officebets.members where id=recipient;
     a:=case when p_args ? 'balance' then (p_args->>'balance')::numeric else old_cost end;
     if coalesce((p_args->>'useAll')::boolean,false) then
       if p_action='buy' then
         if a is null or a<>actor.balance then raise exception 'Balance changed; press Max again and review the quote'; end if;
         a:=actor.balance;
       else select shares into held from officebets.positions where user_id=uid and market_id=m.id and outcome=idx;
         if a is null or a<>held then raise exception 'Position changed; press Max again and review the quote'; end if;
         a:=held; end if;
     end if;
     if a is null or a>1000000000000 or (p_args ? 'balance' and (a<0 or a<>trunc(a,2))) then raise exception 'Use a nonnegative balance with at most two decimals'; end if;
     descr:=case when p_args ? 'bio' then coalesce(btrim(p_args->>'bio'),'') else (select bio from officebets.members where id=recipient) end;
     memo:=case when p_args ? 'avatar' then btrim(p_args->>'avatar') else (select avatar from officebets.members where id=recipient) end;
     if length(descr)>120 or memo is null or length(memo) not between 1 and 16 then raise exception 'Use a short avatar and a bio of at most 120 characters'; end if;
     if not officebets.avatar_allowed(recipient,memo) then raise exception 'This profile icon is locked'; end if;
     update officebets.members set name=title,balance=a,avatar=memo,bio=descr where id=recipient;
     perform officebets.unlock_zero_net_worth(recipient);
     perform officebets.log_entry(recipient,'ADMIN_ADJUST',a-old_cost,'Organizer '||actor.name||' set balance from '||old_cost||' to '||a||'; name: '||title);
   end if;
 elsif p_action='delete_user' then
   -- Keep the actor alive so lost-response retries can use the existing receipt.
   if not actor.is_admin then raise exception using errcode='42501',message='Only an organizer can delete accounts'; end if;
   recipient:=(p_args->>'user')::uuid;
   if recipient is null or recipient=uid then raise exception 'You cannot delete your own active badge'; end if;
   select name,balance into title,a from officebets.members where id=recipient;
   if not found then raise exception 'Account is already gone'; end if;
   if (p_args->>'confirmName') is distinct from title then raise exception 'Badge name changed; review the account and confirm again'; end if;
   -- Preserve prices, collateral and other players. Unclaimed shares are forfeited;
   -- their backing remains in the vault until settlement returns the remainder.
   update officebets.markets set creator=uid where creator=recipient;
   update officebets.persistent_bets set creator=uid where creator=recipient;
   delete from officebets.positions where user_id=recipient;
   delete from officebets.comments where user_id=recipient;
   delete from officebets.requests where user_id=recipient;
   update officebets.ledger set user_id=null where user_id=recipient;
   delete from officebets.member_achievements where member_id=recipient;
   update officebets.house set returned=returned+a where id=1;
   perform officebets.log_entry(null,'HOUSE_RETURN',a,'Unused balance returned after account deletion');
   perform officebets.log_entry(uid,'ACCOUNT_DELETE',0,'Deleted badge: '||title||'; returned '||a||' GW. Positions forfeited; predictions transferred to organizer. Audit history retained.');
   delete from officebets.members where id=recipient;
 elsif p_action='comment' then
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found then raise exception 'Prediction is missing'; end if;
   descr:=btrim(p_args->>'body');
   if descr is null or length(descr) not between 1 and 1000 then raise exception 'Comments must be 1–1000 characters'; end if;
   insert into officebets.comments(market_id,user_id,body) values(m.id,uid,descr);
 elsif p_action in ('create_market','edit_market') then
   if p_action='edit_market' then
     select * into m from officebets.markets where id=(p_args->>'market')::uuid;
     if not found or (m.creator<>uid and not actor.is_admin) then raise exception using errcode='42501',message='Only the author or a verified admin can edit this prediction'; end if;
     if m.winner is not null or m.ever_traded or m.closed_permanently or m.persistent_bet_id is not null then raise exception 'Editing is locked after the first trade, closure or resolution'; end if;
   end if;
   title:=btrim(p_args->>'title'); descr:=coalesce(btrim(p_args->>'description'),''); cat:=p_args->>'category';
   deadline:=(p_args->>'closesAt')::timestamptz;
   select array_agg(btrim(value) order by ord) into names from jsonb_array_elements_text(p_args->'outcomes') with ordinality x(value,ord);
   if title is null or length(title) not between 1 and 180 or length(descr)>2000 then raise exception 'Invalid title or description'; end if;
   if deadline is null or not isfinite(deadline) or deadline<=clock_timestamp() or deadline>clock_timestamp()+interval '1 year' then raise exception 'Closing time must be in the next year'; end if;
   if not exists(select 1 from officebets.categories where id=cat) then raise exception 'Unknown channel'; end if;
   if names is null or cardinality(names) not between 2 and 8 or exists(select 1 from unnest(names) v where v is null or length(v) not between 1 and 60)
      or (select count(distinct lower(v)) from unnest(names) v)<>cardinality(names) then raise exception 'Use 2–8 distinct outcomes, each 1–60 characters'; end if;
   if p_action='create_market' then
     insert into officebets.markets(creator,title,description,category,closes_at,names,reserves)
       values(uid,title,descr,cat,deadline,names,array_fill(200::numeric,array[cardinality(names)])) returning * into m;
     perform set_config('officebets.market_id',m.id::text,true);
     update officebets.house set granted=granted+200 where id=1;
     perform officebets.log_entry(null,'HOUSE_SEED',-200,'House-funded liquidity: '||title);
     perform officebets.log_entry(uid,'MARKET_MINT',0,'Created market: '||title);
   else
     -- No positions ever existed, so changing outcomes is safe. Restart the initial price point.
     delete from officebets.price_history where market_id=m.id;
     update officebets.markets set title=title,description=descr,category=cat,closes_at=deadline,names=names,
       reserves=array_fill(200::numeric,array[cardinality(names)]) where id=m.id;
     perform set_config('officebets.market_id',m.id::text,true);
     perform officebets.log_entry(uid,'MARKET_EDIT',0,'Edited prediction before any trades: '||title);
   end if;
 elsif p_action='delete_market' then
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found then raise exception 'Prediction is already gone'; end if;
   if m.persistent_bet_id is not null then raise exception 'Retire the persistent definition; its instances retain history'; end if;
   if not actor.is_admin and (uid<>m.creator or m.winner is not null or m.ever_traded) then
     raise exception using errcode='42501',message='Only the creator or organizer can delete an untouched prediction; only organizers can wipe traded predictions';
   end if;
   perform set_config('officebets.market_id',m.id::text,true);
   out_amount:=0;
   if m.winner is null then
     for row_p in select * from officebets.positions where market_id=m.id and cost>0 loop
       update officebets.members set balance=balance+row_p.cost where id=row_p.user_id;
       out_amount:=out_amount+row_p.cost;
       perform officebets.log_entry(row_p.user_id,'REFUND',row_p.cost,'Refund of remaining stake after deletion: '||m.title);
     end loop;
   end if;
   residual:=m.vault-out_amount;
   if residual>=0 then
     update officebets.house set returned=returned+residual where id=1;
     perform officebets.log_entry(null,'HOUSE_RETURN',residual,'Collateral returned after deletion: '||m.title);
   else
     update officebets.house set granted=granted-residual where id=1;
     perform officebets.log_entry(null,'HOUSE_SEED',residual,'House covers refund shortfall: '||m.title);
   end if;
   perform officebets.log_entry(uid,'MARKET_DELETE',0,'Deleted prediction: '||m.title||'; refunded '||out_amount||' GW. Completed sales and settlements retained.');
   delete from officebets.positions where market_id=m.id;
   delete from officebets.markets where id=m.id;
 elsif p_action='close_market' then
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found or m.winner is not null or m.closed_permanently then raise exception 'Prediction cannot be closed again'; end if;
   if uid<>m.creator and not actor.is_admin then raise exception using errcode='42501',message='Only creator or verified admin can close this prediction'; end if;
   update officebets.markets set closed_permanently=true,closed_at=clock_timestamp() where id=m.id;
   perform set_config('officebets.market_id',m.id::text,true);
   perform officebets.log_entry(uid,'MARKET_CLOSE',0,'Closed prediction early: '||m.title);
 elsif p_action='reverse_resolution' then
   if not actor.is_admin then raise exception using errcode='42501',message='Verified admin required'; end if;
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found or m.winner is null then raise exception 'Prediction is not resolved'; end if;
   select id into resolution from officebets.resolutions where market_id=m.id and reversed_at is null;
   if resolution is null then raise exception 'Original resolution audit is unavailable'; end if;
   perform set_config('officebets.market_id',m.id::text,true);
   for original_entry in select l.* from officebets.ledger l
     where l.resolution_id=resolution or exists(select 1 from officebets.resolution_entry_links x
       where x.resolution_id=resolution and x.ledger_id=l.id) order by l.id loop
     if original_entry.kind='SETTLEMENT' then
       if original_entry.user_id is null then
         update officebets.house set returned=returned-original_entry.amount where id=1;
       else
         update officebets.members set balance=balance-original_entry.amount where id=original_entry.user_id;
       end if;
     elsif original_entry.kind='HOUSE_RETURN' then
       update officebets.house set returned=returned-original_entry.amount where id=1;
     else raise exception 'Unexpected resolution ledger entry'; end if;
     insert into officebets.ledger(user_id,kind,amount,details,market_id,resolution_id,reverses_ledger_id)
       values(original_entry.user_id,'RESOLUTION_REVERSAL',-original_entry.amount,
         'Reverses resolution ledger #'||original_entry.id||': '||m.title,m.id,resolution,original_entry.id);
   end loop;
   update officebets.resolutions set reversed_at=clock_timestamp(),reversed_by=uid where id=resolution;
   update officebets.markets set winner=null,vault=(select vault_before from officebets.resolutions where id=resolution),
     closed_permanently=true,closed_at=coalesce(closed_at,clock_timestamp()) where id=m.id;
   perform officebets.log_entry(uid,'RESOLUTION_REVERSED',0,'Reversed resolution '||resolution||' for '||m.title);
 elsif p_action in ('create_persistent','edit_persistent','delete_persistent') then
   if not actor.is_admin then raise exception using errcode='42501',message='Verified admin required'; end if;
   if p_action='delete_persistent' then
     select * into recurrence from officebets.persistent_bets where id=(p_args->>'definition')::uuid and active;
     if not found then raise exception 'Persistent bet is already retired'; end if;
     update officebets.persistent_bets set active=false,retired_at=clock_timestamp() where id=recurrence.id;
     update officebets.markets set closed_permanently=true,closed_at=clock_timestamp()
       where persistent_bet_id=recurrence.id and winner is null and not closed_permanently and closes_at>clock_timestamp();
     perform officebets.log_entry(uid,'PERSISTENT_RETIRE',0,'Retired persistent bet: '||recurrence.title);
   else
     title:=btrim(p_args->>'title'); descr:=coalesce(btrim(p_args->>'description'),''); cat:=p_args->>'category';
     memo:=p_args->>'cadence'; weekday:=(p_args->>'weekday')::integer;
     opening:=(p_args->>'closeTime')::time with time zone;
     select array_agg(btrim(value) order by ord) into names from jsonb_array_elements_text(p_args->'outcomes') with ordinality x(value,ord);
     if title is null or length(title) not between 1 and 180 or length(descr)>2000
       or not exists(select 1 from officebets.categories where id=cat)
       or memo not in ('daily','weekly') or opening is null or extract(timezone from opening)<>0
       or (memo='daily' and opening<='07:00:00+00'::time with time zone)
       or (memo='weekly' and weekday not between 0 and 6)
       or names is null or cardinality(names) not between 2 and 8
       or exists(select 1 from unnest(names) v where v is null or length(v) not between 1 and 60)
       or (select count(distinct lower(v)) from unnest(names) v)<>cardinality(names)
     then raise exception 'Invalid persistent bet definition'; end if;
     if p_action='create_persistent' then
       if (select count(*) from officebets.persistent_bets where active)>=3 then raise exception 'Only three active persistent bets are allowed'; end if;
       insert into officebets.persistent_bets(creator,title,description,category,names,cadence,close_time,close_weekday,next_open_at)
       values(uid,title,descr,cat,names,memo,opening,case when memo='weekly' then weekday else null end,
         (date_trunc('day',clock_timestamp() at time zone 'UTC')+time '07:00') at time zone 'UTC'
         + case when (clock_timestamp() at time zone 'UTC')::time>=time '07:00' then interval '1 day' else interval '0' end)
       returning * into recurrence;
       perform officebets.log_entry(uid,'PERSISTENT_CREATE',0,'Created persistent bet: '||title);
     else
       select * into recurrence from officebets.persistent_bets where id=(p_args->>'definition')::uuid and active;
       if not found then raise exception 'Persistent bet is missing'; end if;
       update officebets.persistent_bets set title=title,description=descr,category=cat,names=names,
         cadence=memo,close_time=opening,close_weekday=case when memo='weekly' then weekday else null end
         where id=recurrence.id;
       perform officebets.log_entry(uid,'PERSISTENT_EDIT',0,'Edited future instances of: '||title);
     end if;
     perform officebets.process_persistent_bets(clock_timestamp());
   end if;
 elsif p_action in ('buy','sell','settle') then
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found or m.winner is not null then raise exception 'Market is missing or already settled'; end if;
   perform set_config('officebets.market_id',m.id::text,true);
   idx:=(p_args->>'outcome')::integer; n:=cardinality(m.names);
   if idx is null or idx<0 or idx>=n then raise exception 'Invalid outcome'; end if;
   if p_action='settle' then
     if uid<>m.creator and not actor.is_admin then raise exception using errcode='42501',message='Only the creator or a team admin can settle'; end if;
     insert into officebets.resolutions(market_id,resolved_by,outcome,vault_before) values(m.id,uid,idx,m.vault) returning id into resolution;
     select coalesce(sum(shares),0) into out_amount from officebets.positions where market_id=m.id and outcome=idx;
     if out_amount>m.vault then raise exception 'Market has insufficient collateral'; end if;
     for row_p in select * from officebets.positions where market_id=m.id and shares>0 loop
       a:=case when row_p.outcome=idx then row_p.shares else 0 end;
       update officebets.members set balance=balance+a where id=row_p.user_id;
       insert into officebets.ledger(user_id,kind,amount,details,market_id,resolution_id)
         values(row_p.user_id,'SETTLEMENT',a,'Settled '||m.title||'; winner: '||m.names[idx+1],m.id,resolution);
       if a>0 and row_p.cost>0 and a>=20*row_p.cost then
         insert into officebets.member_achievements(member_id,achievement) values(row_p.user_id,'master_better') on conflict do nothing;
       end if;
     end loop;
     residual:=m.vault-out_amount;
     update officebets.house set returned=returned+residual where id=1;
     insert into officebets.ledger(user_id,kind,amount,details,market_id,resolution_id)
       values(null,'HOUSE_RETURN',residual,'Remaining collateral returned to house: '||m.title,m.id,resolution);
     update officebets.markets set vault=0,winner=idx,closed_permanently=true,closed_at=coalesce(closed_at,clock_timestamp()) where id=m.id;
   else
     if m.closed_permanently or clock_timestamp()>=m.closes_at or (m.opens_at is not null and clock_timestamp()<m.opens_at) then raise exception 'Trading is closed'; end if;
     a:=(p_args->>'amount')::numeric; min_out:=(p_args->>'minOut')::numeric;
     if coalesce((p_args->>'useAll')::boolean,false) then
       if p_action='buy' then
         if a is null or a<>actor.balance then raise exception 'Balance changed; press Max again and review the quote'; end if;
         a:=actor.balance;
       else select shares into held from officebets.positions where user_id=uid and market_id=m.id and outcome=idx;
         if a is null or a<>held then raise exception 'Position changed; press Max again and review the quote'; end if;
         a:=held; end if;
     end if;
     if a is null or not(a between 0.00000001 and 1000000) or min_out is null or not(min_out between 0 and 1000000000) then raise exception 'Invalid trade amount'; end if;
     if not coalesce((p_args->>'useAll')::boolean,false) and a<>trunc(a,10) then raise exception 'At most 10 decimal places are supported'; end if;
     r:=m.reserves; k:=0;
     for i in 1..n loop k:=k+ln(r[i]); end loop;
     if p_action='buy' then
       if a>actor.balance or (not coalesce((p_args->>'useAll')::boolean,false) and (a<0.01 or a<>trunc(a,2))) then raise exception 'Enter an affordable stake with at most two decimals'; end if;
       test_k:=0;
       for i in 1..n loop if i<>idx+1 then r[i]:=r[i]+a; test_k:=test_k+ln(r[i]); end if; end loop;
       out_amount:=trunc(m.reserves[idx+1]+a-exp(k-test_k),10);
       r[idx+1]:=m.reserves[idx+1]+a-out_amount;
       if out_amount<=0 or out_amount<min_out then raise exception 'Price changed; review the updated quote'; end if;
       insert into officebets.positions(user_id,market_id,outcome,shares,cost) values(uid,m.id,idx,out_amount,a)
       on conflict(user_id,market_id,outcome) do update set shares=officebets.positions.shares+excluded.shares,cost=officebets.positions.cost+excluded.cost;
       update officebets.members set balance=balance-a where id=uid;
       m.vault:=m.vault+a;
       perform officebets.log_entry(uid,'BUY',-a,'Bought '||out_amount||' shares of '||m.names[idx+1]||': '||m.title);
       if extract(dow from clock_timestamp() at time zone 'UTC') in (0,6) then
         insert into officebets.member_achievements(member_id,achievement) values(uid,'how_did_we_get_here') on conflict do nothing;
       end if;
     else
       select shares,cost into held,old_cost from officebets.positions where user_id=uid and market_id=m.id and outcome=idx;
       if held is null or a>held then raise exception 'You cannot sell more shares than you own'; end if;
       lo:=0; hi:=a;
       for i in 1..n loop if i<>idx+1 then hi:=least(hi,r[i]); end if; end loop;
       for iter in 1..80 loop
         mid:=(lo+hi)/2; test_k:=ln(r[idx+1]+a-mid);
         for i in 1..n loop if i<>idx+1 then test_k:=test_k+ln(r[i]-mid); end if; end loop;
         if test_k>k then lo:=mid; else hi:=mid; end if;
       end loop;
       out_amount:=trunc(lo,10);
       if out_amount<=0 or out_amount<min_out then raise exception 'Price changed or amount is too small; review the quote'; end if;
       for i in 1..n loop r[i]:=r[i]-out_amount; end loop; r[idx+1]:=r[idx+1]+a;
       update officebets.positions set shares=held-a,cost=case when held=a then 0 else old_cost*(held-a)/held end where user_id=uid and market_id=m.id and outcome=idx;
       update officebets.members set balance=balance+out_amount where id=uid;
       m.vault:=m.vault-out_amount;
       perform officebets.log_entry(uid,'SELL',out_amount,'Sold '||a||' shares of '||m.names[idx+1]||': '||m.title);
     end if;
     if exists(select 1 from unnest(r) v where v<0.00000001 or v>1000000000) then raise exception 'Trade exceeds safe liquidity limits; reduce the amount'; end if;
     if exists(select 1 from officebets.positions where market_id=m.id group by outcome having sum(shares)>m.vault) then raise exception 'Insufficient collateral'; end if;
     update officebets.markets set reserves=r,vault=m.vault,ever_traded=true where id=m.id;
     perform officebets.unlock_zero_net_worth(uid);
   end if;
 elsif p_action in ('add_category','remove_category') then
   if p_action='add_category' then
     title:=btrim(p_args->>'name');
     if title is null or length(title) not between 1 and 25 then raise exception 'Channel names must be 1–25 characters'; end if;
     insert into officebets.categories values(gen_random_uuid()::text,title);
     perform officebets.log_entry(uid,'CHANNEL',0,'Added channel: '||title);
   else
     cat:=p_args->>'category';
     if cat is null or cat='general' or not exists(select 1 from officebets.categories where id=cat) then raise exception 'Cannot delete this channel'; end if;
     update officebets.markets set category='general' where category=cat;
     update officebets.persistent_bets set category='general' where category=cat;
     delete from officebets.categories where id=cat;
     perform officebets.log_entry(uid,'CHANNEL',0,'Removed channel: '||cat);
   end if;
 else raise exception 'Unknown action'; end if;
 perform officebets.unlock_zero_net_worth(uid);
 if p_action in ('settle','reverse_resolution') then
   for row_p in select distinct user_id from officebets.positions where market_id=m.id loop
     perform officebets.unlock_zero_net_worth(row_p.user_id);
   end loop;
 end if;
 insert into officebets.requests(user_id,request_id,action,payload) values(uid,p_request,p_action,p_args);
 update officebets.revision set value=value+1 where id=1;
 return public.ob_snapshot();
end $function$
;


revoke all on function public.ob_action(uuid,uuid,text,jsonb) from public;
grant execute on function public.ob_action(uuid,uuid,text,jsonb) to anon,authenticated;
create extension if not exists pg_cron;
select cron.schedule('officebets-persistent','* * * * *',$$select officebets.process_persistent_bets()$$);
update officebets.revision set value=value+1 where id=1;
notify pgrst,'reload schema';
commit;
