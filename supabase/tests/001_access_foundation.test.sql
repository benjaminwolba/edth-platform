-- Tests for the access foundation: auth_role(), can_read(), can_write(),
-- and RLS on app_users and record_grants.
-- All people here are invented test users.

begin;
create extension if not exists pgtap with schema extensions;

select plan(25);

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres, which bypasses RLS)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@example.test'),
  ('00000000-0000-0000-0000-0000000000c1', 'core@example.test'),
  ('00000000-0000-0000-0000-0000000000d1', 'team@example.test'),
  ('00000000-0000-0000-0000-0000000000f1', 'friend@example.test'),
  ('00000000-0000-0000-0000-0000000000e1', 'external@example.test'),
  ('00000000-0000-0000-0000-0000000000b1', 'inactive@example.test'),
  ('00000000-0000-0000-0000-000000000099', 'nobody@example.test');

insert into public.app_users (user_id, email, display_name, role, active) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@example.test',    'Test Admin',    'admin',    true),
  ('00000000-0000-0000-0000-0000000000c1', 'core@example.test',     'Test Core',     'core',     true),
  ('00000000-0000-0000-0000-0000000000d1', 'team@example.test',     'Test Team',     'team',     true),
  ('00000000-0000-0000-0000-0000000000f1', 'friend@example.test',   'Test Friend',   'friends',  true),
  ('00000000-0000-0000-0000-0000000000e1', 'external@example.test', 'Test External', 'external', true),
  ('00000000-0000-0000-0000-0000000000b1', 'inactive@example.test', 'Test Inactive', 'team',     false);
-- 'nobody' has an auth account but no app_users row.

-- The team user may read one specific confidential organization.
insert into public.record_grants (entity_type, entity_id, user_id, granted_by, reason) values
  ('organizations', '11111111-1111-1111-1111-111111111111',
   '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'test grant');

-- Helper: log in as a user for the rest of the transaction (until reset role).
create function pg_temp.login_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- Reads all four tiers for a dummy entity and returns the visibility as an array.
create function pg_temp.tier_matrix() returns boolean[] language sql as $$
  select array[
    public.can_read('open',         'organizations', '22222222-2222-2222-2222-222222222222'),
    public.can_read('internal',     'organizations', '22222222-2222-2222-2222-222222222222'),
    public.can_read('sensitive',    'organizations', '22222222-2222-2222-2222-222222222222'),
    public.can_read('confidential', 'organizations', '22222222-2222-2222-2222-222222222222')
  ];
$$;

-- ---------------------------------------------------------------------------
-- can_read: one row per role, columns = open / internal / sensitive / confidential
-- ---------------------------------------------------------------------------

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;
select is(public.auth_role(), 'admin'::public.app_role, 'auth_role() returns the user''s role');
select is(pg_temp.tier_matrix(), array[true, true, true, true], 'admin reads every tier');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(pg_temp.tier_matrix(), array[true, true, true, false], 'core reads open, internal, sensitive');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is(pg_temp.tier_matrix(), array[true, true, false, false], 'team reads open, internal');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000f1');
set local role authenticated;
select is(pg_temp.tier_matrix(), array[true, false, false, false], 'friends read open only');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000e1');
set local role authenticated;
select is(pg_temp.tier_matrix(), array[false, false, false, false], 'external reads nothing');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000b1');
set local role authenticated;
select is(public.auth_role(), null::public.app_role, 'inactive user has no role');
select is(pg_temp.tier_matrix(), array[false, false, false, false], 'inactive user reads nothing');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-000000000099');
set local role authenticated;
select is(pg_temp.tier_matrix(), array[false, false, false, false], 'user without app_users row reads nothing');
reset role;

-- ---------------------------------------------------------------------------
-- record_grants: need-to-know access to confidential rows
-- ---------------------------------------------------------------------------

select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is(public.can_read('confidential', 'organizations', '11111111-1111-1111-1111-111111111111'), true,
  'team reads a confidential row it has a grant for');
select is(public.can_read('confidential', 'organizations', '22222222-2222-2222-2222-222222222222'), false,
  'the grant does not extend to other rows');
select is(public.can_read('confidential', 'people', '11111111-1111-1111-1111-111111111111'), false,
  'the grant does not extend to another entity type with the same id');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.can_read('confidential', 'organizations', '11111111-1111-1111-1111-111111111111'), false,
  'another user''s grant does not apply');
reset role;

-- ---------------------------------------------------------------------------
-- can_write
-- ---------------------------------------------------------------------------

select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is(
  array[
    public.can_write('internal',     'organizations', '22222222-2222-2222-2222-222222222222'),
    public.can_write('sensitive',    'organizations', '22222222-2222-2222-2222-222222222222'),
    public.can_write('confidential', 'organizations', '11111111-1111-1111-1111-111111111111')
  ],
  array[true, false, true],
  'team writes internal and granted confidential rows, not sensitive');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000f1');
set local role authenticated;
select is(public.can_write('open', 'organizations', '22222222-2222-2222-2222-222222222222'), false,
  'friends cannot write, even open rows');
reset role;

-- ---------------------------------------------------------------------------
-- app_users RLS
-- ---------------------------------------------------------------------------

select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is((select count(*) from public.app_users), 6::bigint, 'team sees all app users');
update public.app_users set role = 'admin' where user_id = '00000000-0000-0000-0000-0000000000d1';
select throws_ok(
  $$insert into public.app_users (user_id, email, role)
    values ('00000000-0000-0000-0000-000000000099', 'nobody@example.test', 'admin')$$,
  '42501', null, 'team cannot create app users');
reset role;
select is((select role from public.app_users where user_id = '00000000-0000-0000-0000-0000000000d1'),
  'team'::public.app_role, 'team cannot promote itself');

select pg_temp.login_as('00000000-0000-0000-0000-0000000000e1');
set local role authenticated;
select is((select count(*) from public.app_users), 0::bigint, 'external sees no app users');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;
update public.app_users set display_name = 'Renamed' where user_id = '00000000-0000-0000-0000-0000000000d1';
reset role;
select is((select display_name from public.app_users where user_id = '00000000-0000-0000-0000-0000000000d1'),
  'Renamed', 'admin can update app users');

-- ---------------------------------------------------------------------------
-- record_grants RLS
-- ---------------------------------------------------------------------------

select pg_temp.login_as('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is((select count(*) from public.record_grants), 1::bigint, 'team sees its own grant');
select throws_ok(
  $$insert into public.record_grants (entity_type, entity_id, user_id, granted_by, reason)
    values ('organizations', '22222222-2222-2222-2222-222222222222',
            '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1', 'self-grant')$$,
  '42501', null, 'team cannot grant itself access');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*) from public.record_grants), 0::bigint, 'core does not see other users'' grants');
reset role;

-- ---------------------------------------------------------------------------
-- anon (not logged in)
-- ---------------------------------------------------------------------------

set local role anon;
select throws_ok('select * from public.app_users', '42501', null, 'anon cannot read app_users');
reset role;

-- ---------------------------------------------------------------------------
-- Guard for every future table: RLS must be enabled on all tables in public.
-- ---------------------------------------------------------------------------

select is_empty(
  $$select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and not c.relrowsecurity$$,
  'every table in public has RLS enabled');

select * from finish();
rollback;
