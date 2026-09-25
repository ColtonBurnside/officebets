-- Coordinated security cutover. Requires a confirmed, privately linked first admin.
-- NOT backward compatible with unauthenticated organizer actions in the old page.
-- Deploy with the approved UI after the bootstrap/runbook verification; never apply blindly.
begin;
do $$ begin
 if not exists(select 1 from officebets.admin_identities i join officebets.members m on m.id=i.member_id
   join auth.users u on u.id=i.auth_user_id where m.is_admin and m.active and u.email_confirmed_at is not null
   and (u.banned_until is null or u.banned_until<=now())) then
   raise exception 'Link a confirmed first admin identity before enabling verified admin actions (docs/admin-rollout.md)';
 end if;
end $$;

-- All role mutations use the same transaction lock as financial actions. The
-- trigger also protects trusted maintenance updates, deactivation and deletion.
create or replace function officebets.keep_admin_access() returns trigger
language plpgsql set search_path='' as $$
begin
 perform 1 from officebets.revision where id=1 for update;
 if old.is_admin and old.active and (TG_OP='DELETE' or not new.is_admin or not new.active) then
   if not exists(select 1 from officebets.members m join officebets.admin_identities i on i.member_id=m.id
     join auth.users u on u.id=i.auth_user_id where m.id<>old.id and m.is_admin and m.active
       and u.email_confirmed_at is not null and (u.banned_until is null or u.banned_until<=now())) then
     raise exception 'Cannot remove the last active verified admin';
   end if;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end $$;
revoke all on function officebets.keep_admin_access() from public,anon,authenticated;
create trigger keep_admin_access before update of is_admin,active or delete on officebets.members
for each row execute function officebets.keep_admin_access();

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
 title text; descr text; cat text; names text[]; deadline timestamptz; recipient uuid; memo text; row_p record; identity_id uuid; grant_role boolean;
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
 if p_action in ('admin_user','delete_user','admin_role') or
    (actor.is_admin and p_action in ('profile','edit_market','delete_market','settle')) then
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
     descr:=case when p_args ? 'bio' then coalesce(btrim(p_args->>'bio'),'') else (select bio from officebets.members where id=recipient) end;
     memo:=case when p_args ? 'avatar' then btrim(p_args->>'avatar') else (select avatar from officebets.members where id=recipient) end;
     if length(descr)>120 or memo is null or length(memo) not between 1 and 16 then raise exception 'Use a short avatar and a bio of at most 120 characters'; end if;
     update officebets.members set name=title,balance=a,avatar=memo,bio=descr where id=recipient;
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
     if not found or (m.creator<>uid and not actor.is_admin) then raise exception using errcode='42501',message='Only the author or a verified admin can edit this prediction'; end if;
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

revoke all on function public.ob_action(uuid,uuid,text,jsonb) from public;
grant execute on function public.ob_action(uuid,uuid,text,jsonb) to anon,authenticated;
update officebets.revision set value=value+1 where id=1;
notify pgrst,'reload schema';
commit;
