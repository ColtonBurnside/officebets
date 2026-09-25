-- Schema-only fixture captured from OfficeBets before the design/admin migrations.
-- No production rows, identities or credentials. Auth tables below are test doubles.
create role anon; create role authenticated;
create schema auth; create schema officebets;
create table auth.users(id uuid primary key,email text unique,email_confirmed_at timestamptz,banned_until timestamptz);
create table auth.sessions(id uuid primary key,user_id uuid references auth.users);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
create table public.officebets_updates(id integer primary key,revision bigint);
create table officebets.house (id integer not null,
granted numeric(30,12) default 0 not null,
returned numeric(30,12) default 0 not null);
create table officebets.categories (id text not null,
name text not null);
create table officebets.positions (user_id uuid not null,
market_id uuid not null,
outcome integer not null,
shares numeric(30,12) not null,
cost numeric(30,12) not null);
create table officebets.requests (user_id uuid not null,
request_id uuid not null,
action text not null,
payload jsonb not null,
at timestamp with time zone default clock_timestamp() not null);
create table officebets.members (id uuid default gen_random_uuid() not null,
name text not null,
balance numeric(30,12) default 1000 not null,
last_boost timestamp with time zone,
is_admin boolean default false not null,
active boolean default true not null,
avatar text default '🏎️'::text not null,
bio text default ''::text not null);
create table officebets.ledger (id bigint generated always as identity not null,
user_id uuid,
at timestamp with time zone default clock_timestamp() not null,
kind text not null,
amount numeric(30,12) not null,
details text not null,
market_id uuid);
create table officebets.revision (id integer not null,
value bigint default 0 not null);
create table officebets.price_history (id bigint generated always as identity not null,
market_id uuid not null,
at timestamp with time zone default clock_timestamp() not null,
odds numeric[] not null,
kind text not null);
create table officebets.comments (id bigint generated always as identity not null,
market_id uuid not null,
user_id uuid not null,
at timestamp with time zone default clock_timestamp() not null,
body text not null);
create table officebets.markets (id uuid default gen_random_uuid() not null,
creator uuid not null,
title text not null,
description text default ''::text not null,
category text not null,
created_at timestamp with time zone default clock_timestamp() not null,
closes_at timestamp with time zone not null,
names text[] not null,
reserves numeric[] not null,
vault numeric(30,12) default 200 not null,
winner integer,
ever_traded boolean default false not null);
alter table officebets.house add CHECK ((id = 1));
alter table officebets.house add PRIMARY KEY (id);
alter table officebets.categories add CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 25)));
alter table officebets.categories add PRIMARY KEY (id);
alter table officebets.positions add CHECK ((cost >= (0)::numeric));
alter table officebets.positions add PRIMARY KEY (user_id, market_id, outcome);
alter table officebets.positions add CHECK ((shares >= (0)::numeric));
alter table officebets.requests add PRIMARY KEY (user_id, request_id);
alter table officebets.members add CHECK (((length(avatar) >= 1) AND (length(avatar) <= 16)));
alter table officebets.members add CHECK (((balance >= (0)::numeric) AND (balance <= ('1000000000000'::bigint)::numeric)));
alter table officebets.members add CHECK ((length(bio) <= 120));
alter table officebets.members add CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 40)));
alter table officebets.members add PRIMARY KEY (id);
alter table officebets.ledger add PRIMARY KEY (id);
alter table officebets.revision add CHECK ((id = 1));
alter table officebets.revision add PRIMARY KEY (id);
alter table officebets.price_history add PRIMARY KEY (id);
alter table officebets.comments add CHECK (((length(btrim(body)) >= 1) AND (length(btrim(body)) <= 1000)));
alter table officebets.comments add PRIMARY KEY (id);
alter table officebets.markets add CHECK ((((cardinality(names) >= 2) AND (cardinality(names) <= 8)) AND (cardinality(names) = cardinality(reserves))));
alter table officebets.markets add CHECK (((winner IS NULL) OR ((winner >= 0) AND (winner <= (cardinality(names) - 1)))));
alter table officebets.markets add CHECK ((length(description) <= 2000));
alter table officebets.markets add PRIMARY KEY (id);
alter table officebets.markets add CHECK (((length(btrim(title)) >= 1) AND (length(btrim(title)) <= 180)));
alter table officebets.markets add CHECK ((vault >= (0)::numeric));
alter table officebets.positions add FOREIGN KEY (market_id) REFERENCES officebets.markets(id);
alter table officebets.positions add FOREIGN KEY (user_id) REFERENCES officebets.members(id);
alter table officebets.requests add FOREIGN KEY (user_id) REFERENCES officebets.members(id);
alter table officebets.ledger add FOREIGN KEY (user_id) REFERENCES officebets.members(id);
alter table officebets.price_history add FOREIGN KEY (market_id) REFERENCES officebets.markets(id) ON DELETE CASCADE;
alter table officebets.comments add FOREIGN KEY (market_id) REFERENCES officebets.markets(id) ON DELETE CASCADE;
alter table officebets.comments add FOREIGN KEY (user_id) REFERENCES officebets.members(id);
alter table officebets.markets add FOREIGN KEY (category) REFERENCES officebets.categories(id);
alter table officebets.markets add FOREIGN KEY (creator) REFERENCES officebets.members(id);
CREATE OR REPLACE FUNCTION officebets.member_grant()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 perform officebets.log_entry(new.id,'BOOST',new.balance,'Initial play-money grant');
 update officebets.revision set value=value+1 where id=1;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION officebets.log_entry(u uuid, k text, a numeric, d text)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 insert into officebets.ledger(user_id,kind,amount,details,market_id)
 values(u,k,a,d,nullif(current_setting('officebets.market_id',true),'')::uuid)
$function$
;
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
 title text; descr text; cat text; names text[]; deadline timestamptz; recipient uuid; memo text; row_p record;
begin
 perform set_config('officebets.market_id','',true);
 -- Serializes tiny-team mutations; wallets, positions, ledger and receipts commit together.
 perform 1 from officebets.revision where id=1 for update;
 select * into actor from officebets.members where id=uid and active;
 if not found then raise exception using errcode='42501',message='Choose an active teammate badge first.'; end if;
 if p_request is null or p_action is null or p_args is null or jsonb_typeof(p_args)<>'object' or octet_length(p_args::text)>16000 then
   raise exception 'Invalid request'; end if;
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
     if a is null or not(a between 0 and 1000000000000) or (p_args ? 'balance' and a<>trunc(a,2)) then raise exception 'Use a nonnegative balance with at most two decimals'; end if;
     update officebets.members set name=title,balance=a where id=recipient;
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
   delete from officebets.positions where user_id=recipient;
   delete from officebets.comments where user_id=recipient;
   delete from officebets.requests where user_id=recipient;
   update officebets.ledger set user_id=null where user_id=recipient;
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
     if not found or m.creator<>uid then raise exception using errcode='42501',message='Only the author can edit this prediction'; end if;
     if m.winner is not null or m.ever_traded then raise exception 'Editing is locked after the first trade or resolution'; end if;
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
 elsif p_action in ('buy','sell','settle') then
   select * into m from officebets.markets where id=(p_args->>'market')::uuid;
   if not found or m.winner is not null then raise exception 'Market is missing or already settled'; end if;
   perform set_config('officebets.market_id',m.id::text,true);
   idx:=(p_args->>'outcome')::integer; n:=cardinality(m.names);
   if idx is null or idx<0 or idx>=n then raise exception 'Invalid outcome'; end if;
   if p_action='settle' then
     if uid<>m.creator and not actor.is_admin then raise exception using errcode='42501',message='Only the creator or a team admin can settle'; end if;
     select coalesce(sum(shares),0) into out_amount from officebets.positions where market_id=m.id and outcome=idx;
     if out_amount>m.vault then raise exception 'Market has insufficient collateral'; end if;
     for row_p in select * from officebets.positions where market_id=m.id and shares>0 loop
       a:=case when row_p.outcome=idx then row_p.shares else 0 end;
       update officebets.members set balance=balance+a where id=row_p.user_id;
       perform officebets.log_entry(row_p.user_id,'SETTLEMENT',a,'Settled '||m.title||'; winner: '||m.names[idx+1]);
     end loop;
     residual:=m.vault-out_amount;
     update officebets.house set returned=returned+residual where id=1;
     perform officebets.log_entry(null,'HOUSE_RETURN',residual,'Remaining collateral returned to house: '||m.title);
     update officebets.markets set vault=0,winner=idx where id=m.id;
   else
     if clock_timestamp()>=m.closes_at then raise exception 'Trading is closed'; end if;
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
     delete from officebets.categories where id=cat;
     perform officebets.log_entry(uid,'CHANNEL',0,'Removed channel: '||cat);
   end if;
 else raise exception 'Unknown action'; end if;
 insert into officebets.requests(user_id,request_id,action,payload) values(uid,p_request,p_action,p_args);
 update officebets.revision set value=value+1 where id=1;
 return public.ob_snapshot();
end $function$
;
CREATE OR REPLACE FUNCTION officebets.publish_revision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin update public.officebets_updates set revision=new.value where id=1; return new; end $function$
;
CREATE OR REPLACE FUNCTION officebets.record_price()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare probs numeric[];
begin
 select array_agg(case when new.winner is not null then case when i-1=new.winner then 1 else 0 end
 else (1/new.reserves[i])/(select sum(1/v) from unnest(new.reserves) v) end order by i)
 into probs from generate_subscripts(new.reserves,1) i;
 insert into officebets.price_history(market_id,odds,kind) values(new.id,probs,
 case when new.winner is not null then 'RESOLVED' when TG_OP='INSERT' then 'CREATED' else 'TRADE' end);
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.ob_badge(p_request uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare badge officebets.members; label text:=btrim(p_name);
begin
 perform 1 from officebets.revision where id=1 for update;
 if p_request is null or label is null or length(label) not between 1 and 40 then raise exception 'Use a name of 1–40 characters'; end if;
 select * into badge from officebets.members where id=p_request;
 if found then
   if lower(badge.name)<>lower(label) then raise exception 'Badge request already used for a different name'; end if;
 else
   select * into badge from officebets.members where lower(name)=lower(label) order by id limit 1;
   if not found then
     insert into officebets.members(id,name,is_admin)
       values(p_request,label,not exists(select 1 from officebets.members)) returning * into badge;
   end if;
 end if;
 if not badge.active then raise exception 'This badge is inactive; choose another name or ask the organizer'; end if;
 return public.ob_snapshot() || jsonb_build_object('selectedUserId',badge.id);
end $function$
;
CREATE OR REPLACE FUNCTION public.ob_snapshot()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   'slips',(select coalesce(jsonb_agg(jsonb_build_object('id',p.market_id::text||':'||p.outcome,'marketId',p.market_id,
     'outcomeIdx',p.outcome,'shares',p.shares,'sharesExact',p.shares::text,'wager',p.cost,'entryPrice',case when p.shares>0 then p.cost/p.shares else 0 end,
     'settled',m.winner is not null,'payoutReceived',case when m.winner=p.outcome then p.shares else 0 end) order by m.created_at desc),'[]')
     from officebets.positions p join officebets.markets m on m.id=p.market_id where p.user_id=u.id and p.shares>0)
   ) order by u.name),'[]') from officebets.members u),
 'markets',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'creatorId',m.creator,'title',m.title,'description',m.description,
   'categoryId',m.category,'createdAt',m.created_at,'closesAt',m.closes_at,'resolved',m.winner is not null,'winningOutcomeIdx',m.winner,
   'everTraded',m.ever_traded,
   'volume',coalesce((select sum(abs(l.amount)) from officebets.ledger l where l.market_id=m.id and l.kind in ('BUY','SELL')),0),
   'collateralVault',m.vault,'outcomes',(select jsonb_agg(jsonb_build_object('name',m.names[i],'poolReserve',m.reserves[i]) order by i)
     from generate_subscripts(m.names,1) i)) order by m.created_at desc),'[]') from officebets.markets m),
 'transactions',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'timestamp',l.at,'userId',l.user_id,'userName',coalesce(u.name,case when l.kind in ('HOUSE_SEED','HOUSE_RETURN') then 'House' else 'Former teammate' end),
   'type',l.kind,'amount',l.amount,'details',l.details) order by l.id desc),'[]')
   from (select * from officebets.ledger order by id desc limit 500) l left join officebets.members u on u.id=l.user_id)
 ) into result;
 return result;
end $function$
;
CREATE OR REPLACE FUNCTION public.ob_market_view(p_market uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select jsonb_build_object(
 'marketId',p_market,'revision',(select value from officebets.revision where id=1),
 'history',coalesce((select jsonb_agg(jsonb_build_object('id',id,'at',at,'odds',odds,'kind',kind) order by id) from officebets.price_history where market_id=p_market),'[]'),
 'activity',coalesce((select jsonb_agg(x.item order by x.at desc,x.id desc) from (
   (select l.at,l.id,jsonb_build_object('id','t'||l.id,'at',l.at,'userId',l.user_id,'name',coalesce(u.name,case when l.kind in ('HOUSE_SEED','HOUSE_RETURN') then 'House' else 'Former teammate' end),'avatar',coalesce(u.avatar,'⚡'),'kind',l.kind,'amount',l.amount,'text',l.details) item
    from officebets.ledger l left join officebets.members u on u.id=l.user_id where l.market_id=p_market order by l.id desc limit 100)
   union all
   (select c.at,c.id,jsonb_build_object('id','c'||c.id,'at',c.at,'userId',c.user_id,'name',u.name,'avatar',u.avatar,'kind','COMMENT','text',c.body) item
    from officebets.comments c join officebets.members u on u.id=c.user_id where c.market_id=p_market order by c.id desc limit 100)
 ) x),'[]'))
$function$
;
alter table officebets.house enable row level security;
alter table officebets.categories enable row level security;
alter table officebets.positions enable row level security;
alter table officebets.requests enable row level security;
CREATE TRIGGER member_grant AFTER INSERT ON officebets.members FOR EACH ROW EXECUTE FUNCTION officebets.member_grant();
alter table officebets.members enable row level security;
alter table officebets.ledger enable row level security;
CREATE TRIGGER publish_revision AFTER UPDATE ON officebets.revision FOR EACH ROW EXECUTE FUNCTION officebets.publish_revision();
alter table officebets.revision enable row level security;
alter table officebets.price_history enable row level security;
alter table officebets.comments enable row level security;
CREATE TRIGGER record_price AFTER INSERT OR UPDATE OF reserves, winner ON officebets.markets FOR EACH ROW EXECUTE FUNCTION officebets.record_price();
alter table officebets.markets enable row level security;
revoke all on schema officebets from public,anon,authenticated;
revoke all on all tables in schema officebets from public,anon,authenticated;
revoke all on all sequences in schema officebets from public,anon,authenticated;
revoke all on all functions in schema officebets from public,anon,authenticated;
insert into officebets.revision values(1,0);
insert into officebets.house values(1,0,0);
insert into public.officebets_updates values(1,0);
insert into officebets.categories values('general','General');
