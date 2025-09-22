-- =========================================================
-- Schema: Base (Perfis, Firms, Clients, Memberships)
-- Projeto: Azul Contábil
-- =========================================================

-- 1) Criar schema
create schema if not exists azul;

-- 2) Função utilitária para updated_at
create or replace function azul.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- 3) Enums de papéis
do $$
begin
  if not exists (select 1 from pg_type where typname = 'role_enum') then
    create type azul.role_enum as enum (
      'firm_admin',     -- Admin do escritório contábil
      'firm_staff',     -- Colaborador do escritório
      'client_admin',   -- Admin do lado do cliente (empresa atendida)
      'client_user'     -- Usuário comum do cliente
    );
  end if;
end$$;

-- 4) Profiles (espelho de auth.users)
create table if not exists azul.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  avatar_url text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_profiles_updated_at
before update on azul.profiles
for each row execute function azul.set_updated_at();

-- 5) Escritórios (Firms)
create table if not exists azul.firms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique,
  tax_id text,
  email text,
  phone text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_firms_updated_at
before update on azul.firms
for each row execute function azul.set_updated_at();

-- 6) Empresas Clientes (Clients)
create table if not exists azul.clients (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  legal_name text not null,        -- Razão Social
  trade_name text,                 -- Nome Fantasia
  tax_id text unique,              -- CNPJ
  email text,
  phone text,
  address jsonb not null default '{}'::jsonb,
  status text not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_clients_firm on azul.clients(firm_id);

create trigger trg_clients_updated_at
before update on azul.clients
for each row execute function azul.set_updated_at();

-- 7) Memberships (liga usuários a Firms OU Clients)
create table if not exists azul.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references azul.profiles(id) on delete cascade,
  firm_id uuid references azul.firms(id) on delete cascade,
  client_id uuid references azul.clients(id) on delete cascade,
  role azul.role_enum not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memberships_exactly_one_scope check (
    ((firm_id is not null)::int + (client_id is not null)::int) = 1
  )
);

create index if not exists idx_memberships_user on azul.memberships(user_id);
create index if not exists idx_memberships_firm on azul.memberships(firm_id);
create index if not exists idx_memberships_client on azul.memberships(client_id);

-- Partial unique indexes para evitar duplicidades
create unique index if not exists memberships_unique_firm
on azul.memberships(user_id, firm_id, role)
where firm_id is not null;

create unique index if not exists memberships_unique_client
on azul.memberships(user_id, client_id, role)
where client_id is not null;

create trigger trg_memberships_updated_at
before update on azul.memberships
for each row execute function azul.set_updated_at();

-- =========================================================
-- RLS Policies
-- =========================================================

-- Ativar RLS
alter table azul.profiles enable row level security;
alter table azul.firms enable row level security;
alter table azul.clients enable row level security;
alter table azul.memberships enable row level security;

-- PROFILES
drop policy if exists "profiles_self_select" on azul.profiles;
create policy "profiles_self_select"
on azul.profiles
for select
to authenticated
using (
  id = auth.uid()
  or exists (
    select 1
    from azul.memberships m_me
    join azul.memberships m_tgt
      on m_tgt.user_id = azul.profiles.id
     and (
        (m_me.firm_id is not null and m_me.firm_id = m_tgt.firm_id)
      or (m_me.client_id is not null and m_me.client_id = m_tgt.client_id)
     )
    where m_me.user_id = auth.uid()
  )
);

drop policy if exists "profiles_self_update" on azul.profiles;
create policy "profiles_self_update"
on azul.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- FIRMS
drop policy if exists "firms_read_own" on azul.firms;
create policy "firms_read_own"
on azul.firms
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.firms.id
  )
);

drop policy if exists "firms_update_admin" on azul.firms;
create policy "firms_update_admin"
on azul.firms
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.firms.id
      and m.role = 'firm_admin'
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.firms.id
      and m.role = 'firm_admin'
  )
);

-- CLIENTS
drop policy if exists "clients_read_by_scope" on azul.clients;
create policy "clients_read_by_scope"
on azul.clients
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.clients.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or exists (
    select 1 from azul.memberships m2
    where m2.user_id = auth.uid()
      and m2.client_id = azul.clients.id
  )
);

drop policy if exists "clients_insert_firm" on azul.clients;
create policy "clients_insert_firm"
on azul.clients
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.clients.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "clients_update_firm" on azul.clients;
create policy "clients_update_firm"
on azul.clients
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.clients.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.clients.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "clients_delete_firm" on azul.clients;
create policy "clients_delete_firm"
on azul.clients
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.clients.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- MEMBERSHIPS
drop policy if exists "memberships_read_by_scope" on azul.memberships;
create policy "memberships_read_by_scope"
on azul.memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from azul.memberships me
    where me.user_id = auth.uid()
      and me.firm_id = azul.memberships.firm_id
      and me.role in ('firm_admin','firm_staff')
  )
  or exists (
    select 1 from azul.memberships me2
    where me2.user_id = auth.uid()
      and me2.client_id = azul.memberships.client_id
      and me2.role = 'client_admin'
  )
);

drop policy if exists "memberships_insert_by_firm_admin" on azul.memberships;
create policy "memberships_insert_by_firm_admin"
on azul.memberships
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships me
    where me.user_id = auth.uid()
      and me.role = 'firm_admin'
      and (
        (me.firm_id is not null and me.firm_id = coalesce(azul.memberships.firm_id,
                                                          (select c.firm_id from azul.clients c where c.id = azul.memberships.client_id)))
      )
  )
);

drop policy if exists "memberships_update_by_firm_admin" on azul.memberships;
create policy "memberships_update_by_firm_admin"
on azul.memberships
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships me
    where me.user_id = auth.uid()
      and me.role = 'firm_admin'
      and (
        (me.firm_id is not null and me.firm_id = azul.memberships.firm_id) or
        (
          me.firm_id is not null and exists (
            select 1 from azul.clients c
            where c.id = azul.memberships.client_id
              and c.firm_id = me.firm_id
          )
        )
      )
  )
)
with check (
  exists (
    select 1 from azul.memberships me
    where me.user_id = auth.uid()
      and me.role = 'firm_admin'
      and (
        (me.firm_id is not null and me.firm_id = coalesce(azul.memberships.firm_id,
                                                          (select c.firm_id from azul.clients c where c.id = azul.memberships.client_id)))
      )
  )
);

drop policy if exists "memberships_delete_by_firm_admin" on azul.memberships;
create policy "memberships_delete_by_firm_admin"
on azul.memberships
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships me
    where me.user_id = auth.uid()
      and me.role = 'firm_admin'
      and (
        (me.firm_id is not null and me.firm_id = azul.memberships.firm_id) or
        (
          me.firm_id is not null and exists (
            select 1 from azul.clients c
            where c.id = azul.memberships.client_id
              and c.firm_id = me.firm_id
          )
        )
      )
  )
);
