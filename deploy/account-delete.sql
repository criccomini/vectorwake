\if :{?account_id}
\else
  \echo 'usage: psql "$(./deploy/fleet.sh db --url)" -v account_id=<number> -f deploy/account-delete.sql'
  \quit 2
\endif

\set ON_ERROR_STOP on

begin;

create temporary table account_delete_targets (
    id bigint primary key
) on commit drop;

with recursive targets(id) as (
    select id from accounts where id = :'account_id'::bigint
    union all
    select child.id
    from accounts child join targets parent on child.owner = parent.id
)
insert into account_delete_targets select id from targets;

select count(*) > 0 as found from account_delete_targets \gset

\if :found
\else
  rollback;
  \echo 'No account has that number. Nothing deleted.'
  \quit 2
\endif

select not exists (
    select 1
    from account_delete_targets d
    join accounts a on a.id = d.id
    where a.admin
) or exists (
    select 1 from accounts a
    where a.admin and a.id not in (select id from account_delete_targets)
) as leaves_admin \gset

\if :leaves_admin
\else
  rollback;
  \echo 'This would delete the last admin. Transfer admin first. Nothing deleted.'
  \quit 2
\endif

\echo 'The following accounts and registered bots will be deleted:'
select a.id, coalesce(n.call_sign, 'Pilot ' || a.id::text) as call_sign,
       a.kind, a.created, a.last_seen
from account_delete_targets d
join accounts a on a.id = d.id
left join names n on n.account = a.id
order by a.id;

\prompt 'Type DELETE to remove these accounts: ' confirmation
select :'confirmation' = 'DELETE' as confirmed \gset

\if :confirmed
  delete from pilot_events
  where pilot in (select id from account_delete_targets);

  delete from accounts
  where id in (select id from account_delete_targets);

  commit;
  \echo 'Account data and linked pilot activity deleted. Rated match rows remain deidentified.'
\else
  rollback;
  \echo 'Nothing deleted.'
\endif
