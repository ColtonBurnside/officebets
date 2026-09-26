-- Cover the foreign keys introduced by the recurring-market and resolution audit migration.
create index if not exists ledger_resolution_entries on officebets.ledger(resolution_id,id);
create index if not exists persistent_bets_category on officebets.persistent_bets(category);
create index if not exists persistent_bets_creator on officebets.persistent_bets(creator);
