-- =========================================================
-- Schema: Integrações (Omie, Komunic, Acessorias)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql
-- =========================================================

-- 0) Garantir UNIQUE composta em clients (id, firm_id)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'clients_id_firm_unique'
      and conrelid = 'azul.clients'::regclass
  ) then
    alter table azul.clients
      add constraint clients_id_firm_unique unique (id, firm_id);
  end if;
end$$;

-- =========================================================
-- 1) Enums
-- =========================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'integration_provider_enum') then
    create type azul.integration_provider_enum as enum ('omie','komunic','acessorias','other');
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_kind_enum') then
    create type azul.integration_kind_enum as enum ('erp','messaging','docs','webhook','other');
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_status_enum') then
    create type azul.integration_status_enum as enum ('disabled','enabled','pending','connected','error');
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_auth_enum') then
    create type azul.integration_auth_enum as enum ('none','api_key','oauth2','basic','custom');
  end if;

  if not exists (select 1 from pg_type where typname = 'job_status_enum') then
    create type azul.job_status_enum as enum ('queued','running','success','failed','canceled');
  end if;

  if not exists (select 1 from pg_type where typname = 'job_operation_enum') then
    create type azul.job_operation_enum as enum ('pull','push','full_sync','delta');
  end if;

  if not exists (select 1 from pg_type where typname = 'message_direction_enum') then
    create type azul.message_direction_enum as enum ('inbound','outbound');
  end if;

  if not exists (select 1 from pg_type where typname = 'message_channel_enum') then
    create type azul.message_channel_enum as enum ('komunic','whatsapp','sms','email','push','webhook');
  end if;

  if not exists (select 1 from pg_type where typname = 'message_status_enum') then
    create type azul.message_status_enum as enum ('queued','sent','delivered','read','failed');
  end if;
end$$;

-- =========================================================
-- 2) Conexões
-- =========================================================
create table if not exists azul.integration_connections (
  id uuid primary key default gen_random_uuid(),
  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid,
  provider  azul.integration_provider_enum not null,
  kind      azul.integration_kind_enum not null,
  name      text,
  env       text,
  status    azul.integration_status_enum not null default 'pending',
  auth_type azul.integration_auth_enum not null default 'none',
  secret_ref text,
  settings   jsonb not null default '{}'::jsonb,
  last_synced_at timestamptz,
  last_error_at  timestamptz,
  last_error_msg text,
  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint integration_conn_client_firm_fk
    foreign key (client_id, firm_id) references azul.clients(id, firm_id) on delete cascade
);

-- 🔧 UNIQUE por firm+provider+env (sem coalesce)
create unique index if not exists uidx_integration_connections_scope
  on azul.integration_connections(firm_id, provider, env);

create index if not exists idx_integration_connections_firm on azul.integration_connections(firm_id);
create index if not exists idx_integration_connections_client on azul.integration_connections(client_id);
create index if not exists idx_integration_connections_provider on azul.integration_connections(provider);

create trigger trg_integration_connections_updated_at
before update on azul.integration_connections
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Tokens
-- =========================================================
create table if not exists azul.integration_tokens (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,
  access_token_ref text,
  refresh_token_ref text,
  scope text,
  expires_at timestamptz,
  rotated_at timestamptz,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- =========================================================
-- 4) Webhooks
-- =========================================================
create table if not exists azul.integration_webhooks (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,
  external_id text,
  event text not null,
  target_url text,
  secret_ref text,
  is_active boolean not null default true,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

-- =========================================================
-- 5) Jobs
-- =========================================================
create table if not exists azul.integration_jobs (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,
  operation azul.job_operation_enum not null,
  resource text,
  since timestamptz,
  until timestamptz,
  status azul.job_status_enum not null default 'queued',
  started_at timestamptz,
  finished_at timestamptz,
  error_msg text,
  stats jsonb not null default '{}'::jsonb,
  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- =========================================================
-- 6) Entities Map
-- =========================================================
create table if not exists azul.integration_entities_map (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,
  local_type text not null,
  local_id uuid,
  external_type text not null,
  external_id text not null,
  last_synced_at timestamptz,
  external_payload jsonb,
  created_at timestamptz not null default now()
);

-- 🔧 Índices únicos (sem coalesce, usando índices parciais)
create unique index if not exists uidx_entities_map_local_notnull
  on azul.integration_entities_map(connection_id, local_type, local_id)
  where local_id is not null;

create unique index if not exists uidx_entities_map_local_null
  on azul.integration_entities_map(connection_id, local_type)
  where local_id is null;

create unique index if not exists uidx_entities_map_external
  on azul.integration_entities_map(connection_id, external_type, external_id);

-- =========================================================
-- 7) Mensagens
-- =========================================================
create table if not exists azul.integration_messages (
  id uuid primary key default gen_random_uuid(),
  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid,
  connection_id uuid references azul.integration_connections(id) on delete set null,
  direction azul.message_direction_enum not null,
  channel azul.message_channel_enum not null default 'komunic',
  to_phone text,
  to_email text,
  to_user_id uuid references azul.profiles(id) on delete set null,
  from_phone text,
  from_email text,
  template text,
  variables jsonb not null default '{}'::jsonb,
  content text,
  status azul.message_status_enum not null default 'queued',
  provider_message_id text,
  error_msg text,
  attempts int not null default 0,
  scheduled_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint msg_address_chk check (
    (direction = 'inbound') or (coalesce(to_phone, to_email, to_user_id::text) is not null)
  )
);

-- FK composta opcional
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'integration_messages_client_firm_fk'
      and conrelid = 'azul.integration_messages'::regclass
  ) then
    alter table azul.integration_messages
      add constraint integration_messages_client_firm_fk
      foreign key (client_id, firm_id)
      references azul.clients(id, firm_id)
      on delete cascade;
  end if;
end$$;

create trigger trg_integration_messages_updated_at
before update on azul.integration_messages
for each row execute function azul.set_updated_at();

-- =========================================================
-- 8) RLS (apenas exemplos resumidos, expanda conforme 07 original)
-- =========================================================
alter table azul.integration_connections  enable row level security;
alter table azul.integration_tokens       enable row level security;
alter table azul.integration_webhooks     enable row level security;
alter table azul.integration_jobs         enable row level security;
alter table azul.integration_entities_map enable row level security;
alter table azul.integration_messages     enable row level security;

-- exemplo: staff da firm pode SELECT connections
drop policy if exists "conn_select_staff" on azul.integration_connections;
create policy "conn_select_staff"
on azul.integration_connections
for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);
