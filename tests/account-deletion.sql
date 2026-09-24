-- Run only against an isolated v10+ test database with the discovery migration.
-- Synthetic fixtures and actions roll back. Never deletes a pre-existing badge.
begin;
do $$
#variable_conflict use_variable
declare
 admin_id uuid:=gen_random_uuid(); member_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid();
 market_id uuid; solo_id uuid; early_id uuid; request_id uuid:=gen_random_uuid(); result jsonb;
 before_vault numeric; before_reserves numeric[]; before_balance numeric; before_returned numeric;
 deleted_balance numeric; other_shares numeric; before_volume numeric; r bigint;
begin
 insert into officebets.members(id,name,is_admin) values(admin_id,'Test organizer '||left(admin_id::text,8),true);
 insert into officebets.members(id,name) values(member_id,'Delete fixture '||left(member_id::text,8)),(other_id,'Other fixture '||left(other_id::text,8));
 perform public.ob_action(gen_random_uuid(),member_id,'create_market',jsonb_build_object('title','Deletion fixture','description','','category','general','closesAt',clock_timestamp()+interval '1 day','outcomes',jsonb_build_array('YES','NO')));
 select id into market_id from officebets.markets where creator=member_id;
 -- Admin resolves another creator's prediction while trading is still open.
 insert into officebets.markets(creator,title,category,closes_at,names,reserves)
 values(member_id,'Early resolution fixture','general',clock_timestamp()+interval '1 day',array['YES','NO'],array[200,200]) returning id into early_id;
 begin
   perform public.ob_action(gen_random_uuid(),other_id,'settle',jsonb_build_object('market',early_id,'outcome',0));
   raise exception 'TEST FAILED: unrelated teammate can resolve';
 exception when insufficient_privilege then null; end;
 perform public.ob_action(gen_random_uuid(),admin_id,'settle',jsonb_build_object('market',early_id,'outcome',0));
 assert (select winner=0 and closes_at>clock_timestamp() from officebets.markets where id=early_id),'Admin early resolution failed';

 perform public.ob_action(gen_random_uuid(),member_id,'buy',jsonb_build_object('market',market_id,'outcome',0,'amount',100,'minOut',0));
 perform public.ob_action(gen_random_uuid(),other_id,'buy',jsonb_build_object('market',market_id,'outcome',1,'amount',50,'minOut',0));
 perform public.ob_action(gen_random_uuid(),member_id,'sell',jsonb_build_object('market',market_id,'outcome',0,'amount',10,'minOut',0));
 perform public.ob_action(gen_random_uuid(),member_id,'comment',jsonb_build_object('market',market_id,'body','Delete this fixture comment'));
 perform public.ob_action(gen_random_uuid(),member_id,'create_market',jsonb_build_object('title','Solo fixture','description','','category','general','closesAt',clock_timestamp()+interval '1 day','outcomes',jsonb_build_array('YES','NO')));
 select id into solo_id from officebets.markets where creator=member_id and id not in (market_id,early_id);
 perform public.ob_action(gen_random_uuid(),member_id,'buy',jsonb_build_object('market',solo_id,'outcome',0,'amount',10,'minOut',0));
 select vault,reserves into before_vault,before_reserves from officebets.markets where id=market_id;
 select balance into before_balance from officebets.members where id=other_id;
 select balance into deleted_balance from officebets.members where id=member_id;
 select returned into before_returned from officebets.house where id=1;
 select shares into other_shares from officebets.positions where user_id=other_id and officebets.positions.market_id=market_id;
 select sum(abs(amount)) into before_volume from officebets.ledger l where l.market_id=market_id and kind in ('BUY','SELL');
 begin
   perform public.ob_action(gen_random_uuid(),other_id,'delete_user',jsonb_build_object('user',member_id,'confirmName',(select name from officebets.members where id=member_id)));
   raise exception 'TEST FAILED: non-admin deletion allowed';
 exception when insufficient_privilege then null; end;
 begin
   perform public.ob_action(gen_random_uuid(),admin_id,'delete_user',jsonb_build_object('user',admin_id));
   raise exception 'TEST FAILED: self-deletion allowed';
 exception when raise_exception then if SQLERRM<>'You cannot delete your own active badge' then raise; end if; end;
 begin
   perform public.ob_action(gen_random_uuid(),admin_id,'delete_user',jsonb_build_object('user',member_id,'confirmName','wrong'));
   raise exception 'TEST FAILED: wrong confirmation allowed';
 exception when raise_exception then if SQLERRM<>'Badge name changed; review the account and confirm again' then raise; end if; end;
 result:=jsonb_build_object('user',member_id,'confirmName',(select name from officebets.members where id=member_id));
 perform public.ob_action(request_id,admin_id,'delete_user',result);
 assert not exists(select 1 from officebets.members where id=member_id),'Badge remains';
 assert not exists(select 1 from officebets.positions where user_id=member_id),'Positions remain';
 assert not exists(select 1 from officebets.comments where user_id=member_id),'Comments remain';
 assert not exists(select 1 from officebets.requests where user_id=member_id),'Requests remain';
 assert not exists(select 1 from officebets.ledger where user_id=member_id),'Ledger references deleted badge';
 assert (select creator=admin_id and vault=before_vault and reserves=before_reserves from officebets.markets where id=market_id),'Market prices or vault changed';
 assert (select balance=before_balance from officebets.members where id=other_id),'Other wallet changed';
 assert (select returned=before_returned+deleted_balance from officebets.house where id=1),'Unused wallet not returned';
 assert (select ever_traded from officebets.markets where id=solo_id),'Solo market edit lock lost';
 assert (select (v->>'volume')::numeric=before_volume from jsonb_array_elements(public.ob_snapshot()->'markets') v where v->>'id'=market_id::text),'Volume lost after deletion';
 assert exists(select 1 from jsonb_array_elements(public.ob_market_view(market_id)->'activity') v where v->>'name'='Former teammate' and v->>'kind'='BUY'),'Deleted trade attribution incorrect';
 select value into r from officebets.revision where id=1;
 perform public.ob_action(request_id,admin_id,'delete_user',result);
 assert (select value=r from officebets.revision where id=1),'Retry applied twice';
 begin
   perform public.ob_action(gen_random_uuid(),member_id,'boost','{}');
   raise exception 'TEST FAILED: deleted badge can act';
 exception when insufficient_privilege then null; end;
 begin
   perform public.ob_action(gen_random_uuid(),admin_id,'edit_market',jsonb_build_object('market',solo_id));
   raise exception 'TEST FAILED: traded solo market editable';
 exception when raise_exception then if SQLERRM<>'Editing is locked after the first trade or resolution' then raise; end if; end;
 perform public.ob_action(gen_random_uuid(),admin_id,'settle',jsonb_build_object('market',market_id,'outcome',1));
 assert (select balance=before_balance+other_shares from officebets.members where id=other_id),'Remaining winner payout incorrect';
end $$;
rollback;
