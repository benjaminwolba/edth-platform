-- Access foundation: tiers, roles, app users, need-to-know grants and the
-- helper functions every RLS policy in this database is built on.
-- See "Access model" in docs/DATA_MODEL.md.

create extension if not exists citext with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type public.tier as enum ('open', 'internal', 'sensitive', 'confidential');

create type public.app_role as enum ('admin', 'core', 'team', 'friends', 'external');

-- ---------------------------------------------------------------------------
-- updated_at trigger, used by every table
-- ---------------------------------------------------------------------------

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- app_users: who may use the app, and with which role.
-- The primary key is the Supabase auth user id, so every "user" reference in
-- the schema (created_by, owner_user_id, ...) is simply auth.uid().
-- No row, or active = false, means no access at all.
-- ---------------------------------------------------------------------------

create table public.app_users (
  user_id      uuid primary key references auth.users (id) on delete restrict,
  email        extensions.citext not null unique,
  display_name text,
  role         public.app_role not null,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger app_users_set_updated_at
  before update on public.app_users
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- record_grants: need-to-know access to individual confidential rows.
-- ---------------------------------------------------------------------------

create table public.record_grants (
  id          uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type ~ '^[a-z_]+$'),
  entity_id   uuid not null,
  user_id     uuid not null references public.app_users (user_id) on delete cascade,
  granted_by  uuid not null references public.app_users (user_id),
  reason      text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (entity_type, entity_id, user_id)
);

create trigger record_grants_set_updated_at
  before update on public.record_grants
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

-- The current user's role, or null if they are not an active app user.
create function public.auth_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.app_users
  where user_id = auth.uid()
    and active;
$$;

-- Whether the current user may read a row with this tier.
--   open         -> friends, team, core, admin
--   internal     -> team, core, admin
--   sensitive    -> core, admin
--   confidential -> admin, plus friends/team/core with a record_grants row
-- 'external' users get nothing here; EDTH Intelligence will use separate views.
create function public.can_read(p_tier public.tier, p_entity_type text, p_entity_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role := public.auth_role();
begin
  if v_role is null or v_role = 'external' then
    return false;
  end if;

  if v_role = 'admin' then
    return true;
  end if;

  if p_tier = 'open' then
    return true;
  elsif p_tier = 'internal' then
    return v_role in ('team', 'core');
  elsif p_tier = 'sensitive' then
    return v_role = 'core';
  elsif p_tier = 'confidential' then
    return exists (
      select 1
      from public.record_grants g
      where g.user_id = auth.uid()
        and g.entity_type = p_entity_type
        and g.entity_id = p_entity_id
    );
  end if;

  return false;
end;
$$;

-- Whether the current user may write a row with this tier:
-- team, core or admin, and only rows they can also read.
create function public.can_write(p_tier public.tier, p_entity_type text, p_entity_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.auth_role() in ('admin', 'core', 'team'), false)
     and public.can_read(p_tier, p_entity_type, p_entity_id);
$$;

revoke execute on function public.auth_role() from anon, public;
revoke execute on function public.can_read(public.tier, text, uuid) from anon, public;
revoke execute on function public.can_write(public.tier, text, uuid) from anon, public;
grant execute on function public.auth_role() to authenticated;
grant execute on function public.can_read(public.tier, text, uuid) to authenticated;
grant execute on function public.can_write(public.tier, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges: nothing in public is reachable without logging in.
-- ---------------------------------------------------------------------------

revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.app_users enable row level security;
alter table public.record_grants enable row level security;

-- Every internal app user can see who the other app users are (for assignees,
-- "reviewed by", etc.). Only admins change users or roles.
create policy app_users_select on public.app_users
  for select to authenticated
  using (public.auth_role() in ('admin', 'core', 'team', 'friends'));

create policy app_users_admin_insert on public.app_users
  for insert to authenticated
  with check (public.auth_role() = 'admin');

create policy app_users_admin_update on public.app_users
  for update to authenticated
  using (public.auth_role() = 'admin')
  with check (public.auth_role() = 'admin');

-- Users see their own grants; admins see and manage all grants.
create policy record_grants_select on public.record_grants
  for select to authenticated
  using (user_id = auth.uid() or public.auth_role() = 'admin');

create policy record_grants_admin_insert on public.record_grants
  for insert to authenticated
  with check (public.auth_role() = 'admin');

create policy record_grants_admin_update on public.record_grants
  for update to authenticated
  using (public.auth_role() = 'admin')
  with check (public.auth_role() = 'admin');

create policy record_grants_admin_delete on public.record_grants
  for delete to authenticated
  using (public.auth_role() = 'admin');
