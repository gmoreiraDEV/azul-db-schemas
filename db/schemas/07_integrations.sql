-- =========================================================
-- Schema: Integrações (Omie, Komunic, Acessorias)
-- Projeto: Azul Contábil
-- Pré-requisitos: 01_base.sql
-- =========================================================

-- 0) Garantir UNIQUE composta em clients (id, firm_id) para FKs compostas
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
    create type azul.integration_provider_enum as enum (
      'omie',
      'komunic',
      'acessorias',
      'other'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_kind_enum') then
    create type azul.integration_kind_enum as enum (
      'erp',        -- ex.: Omie
      'messaging',  -- ex.: Komunic
      'docs',       -- acessórias/documentais
      'webhook',
      'other'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_status_enum') then
    create type azul.integration_status_enum as enum (
      'disabled','enabled','pending','connected','error'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'integration_auth_enum') then
    create type azul.integration_auth_enum as enum (
      'none','api_key','oauth2','basic','custom'
    );
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
-- 2) Conexões de Integração (por firm e opcionalmente por client)
-- =========================================================
create table if not exists azul.integration_connections (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid, -- opcional (ex.: conexão específica por cliente)
  provider  azul.integration_provider_enum not null,
  kind      azul.integration_kind_enum     not null,
  name      text,           -- rótulo amigável (ex.: "Omie produção", "Komunic principal")
  env       text,           -- dev/staging/prod (livre)

  status    azul.integration_status_enum not null default 'pending',
  auth_type azul.integration_auth_enum   not null default 'none',

  -- segurança: NÃO armazene segredos em plaintext
  secret_ref text,          -- referência a cofre (Vault/KMS/Env)
  settings   jsonb not null default '{}'::jsonb, -- configs (domínio, tenant, escopos etc.)

  last_synced_at timestamptz,
  last_error_at  timestamptz,
  last_error_msg text,

  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint integration_conn_client_firm_fk
    foreign key (client_id, firm_id) references azul.clients(id, firm_id) on delete cascade
);

create unique index if not exists uidx_integration_connections_scope
  on azul.integration_connections(firm_id, coalesce(client_id, '00000000-0000-0000-0000-000000000000'::uuid), provider, coalesce(env,'default'));

create index if not exists idx_integration_connections_firm on azul.integration_connections(firm_id);
create index if not exists idx_integration_connections_client on azul.integration_connections(client_id);
create index if not exists idx_integration_connections_provider on azul.integration_connections(provider);

create trigger trg_integration_connections_updated_at
before update on azul.integration_connections
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Tokens (metadados de OAuth2/API) – sem segredos
-- =========================================================
create table if not exists azul.integration_tokens (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,

  access_token_ref  text,       -- referência segura ao token
  refresh_token_ref text,       -- referência segura ao refresh
  scope text,
  expires_at timestamptz,
  rotated_at timestamptz,

  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_integration_tokens_conn on azul.integration_tokens(connection_id);
create index if not exists idx_integration_tokens_exp on azul.integration_tokens(expires_at);

-- =========================================================
-- 4) Webhooks (assinaturas/segredos/endpoints)
-- =========================================================
create table if not exists azul.integration_webhooks (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,

  external_id text,     -- id do provedor (quando houver)
  event       text not null, -- tipo de evento (livre: ex.: 'invoice.created', 'message.inbound')
  target_url  text,     -- URL alvo (para webhooks de SAÍDA que a gente chama)
  secret_ref  text,     -- segredo para validação de ASSINATURA do provedor
  is_active   boolean not null default true,

  last_seen_at timestamptz,
  created_at   timestamptz not null default now()
);

create index if not exists idx_integration_webhooks_conn on azul.integration_webhooks(connection_id);
create index if not exists idx_integration_webhooks_event on azul.integration_webhooks(event);

-- =========================================================
-- 5) Jobs de Sincronização (pull/push/full/delta)
-- =========================================================
create table if not exists azul.integration_jobs (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,

  operation azul.job_operation_enum not null,  -- pull/push/full_sync/delta
  resource  text,                              -- ex.: 'customers','invoices','products','messages'
  since     timestamptz,
  until     timestamptz,

  status azul.job_status_enum not null default 'queued',
  started_at  timestamptz,
  finished_at timestamptz,
  error_msg   text,

  stats jsonb not null default '{}'::jsonb,    -- {inserted, updated, skipped, failed, ...}
  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_integration_jobs_conn on azul.integration_jobs(connection_id);
create index if not exists idx_integration_jobs_status on azul.integration_jobs(status);
create index if not exists idx_integration_jobs_resource on azul.integration_jobs(resource);

-- =========================================================
-- 6) Mapeamento de Entidades Externas (para Omie/Acessorias)
-- =========================================================
create table if not exists azul.integration_entities_map (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,

  local_type   text not null, -- ex.: 'client','invoice','product','service'
  local_id     uuid,          -- id local (quando houver; p/ client use clients.id)
  external_type text not null, -- ex.: 'cliente','nfse','produto' (nome no provedor)
  external_id   text not null,

  last_synced_at timestamptz,
  external_payload jsonb,     -- último payload conhecido (debug/auditoria)

  unique (connection_id, local_type, coalesce(local_id, '00000000-0000-0000-0000-000000000000')),
  unique (connection_id, external_type, external_id)
);

create index if not exists idx_entities_map_conn on azul.integration_entities_map(connection_id);
create index if not exists idx_entities_map_local on azul.integration_entities_map(local_type, local_id);
create index if not exists idx_entities_map_external on azul.integration_entities_map(external_type, external_id);

-- =========================================================
-- 7) Mensageria (Komunic / omnicanal)
-- =========================================================
create table if not exists azul.integration_messages (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid, -- opcional (mensagens ligadas a um cliente)
  connection_id uuid references azul.integration_connections(id) on delete set null,

  direction azul.message_direction_enum not null, -- outbound/inbound
  channel   azul.message_channel_enum   not null default 'komunic',

  -- endereçamento
  to_phone   text,
  to_email   text,
  to_user_id uuid references azul.profiles(id) on delete set null,
  from_phone text,
  from_email text,

  -- conteúdo
  template   text,             -- opcional: nome do template
  variables  jsonb not null default '{}'::jsonb,
  content    text,             -- corpo final (texto)

  -- rastreio
  status azul.message_status_enum not null default 'queued',
  provider_message_id text,
  error_msg text,

  attempts int not null default 0,
  scheduled_at timestamptz,
  sent_at      timestamptz,
  delivered_at timestamptz,
  read_at      timestamptz,

  created_by uuid references azul.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint msg_address_chk check (
    (direction = 'inbound')
    or (coalesce(to_phone, to_email, to_user_id::text) is not null)
  )
);

-- FK composta opcional para client
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

create index if not exists idx_integration_messages_firm     on azul.integration_messages(firm_id);
create index if not exists idx_integration_messages_client   on azul.integration_messages(client_id);
create index if not exists idx_integration_messages_channel  on azul.integration_messages(channel);
create index if not exists idx_integration_messages_status   on azul.integration_messages(status);
create index if not exists idx_integration_messages_direction on azul.integration_messages(direction);
create index if not exists idx_integration_messages_sched    on azul.integration_messages(scheduled_at);

create trigger trg_integration_messages_updated_at
before update on azul.integration_messages
for each row execute function azul.set_updated_at();

-- =========================================================
-- 8) RLS
-- =========================================================
alter table azul.integration_connections  enable row level security;
alter table azul.integration_tokens       enable row level security;
alter table azul.integration_webhooks     enable row level security;
alter table azul.integration_jobs         enable row level security;
alter table azul.integration_entities_map enable row level security;
alter table azul.integration_messages     enable row level security;

-- ----------------------------
-- CONNECTIONS
-- ----------------------------
drop policy if exists "conn_select_staff" on azul.integration_connections;
create policy "conn_select_staff"
on azul.integration_connections
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "conn_insert_staff" on azul.integration_connections;
create policy "conn_insert_staff"
on azul.integration_connections
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "conn_update_staff" on azul.integration_connections;
create policy "conn_update_staff"
on azul.integration_connections
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "conn_delete_admin" on azul.integration_connections;
create policy "conn_delete_admin"
on azul.integration_connections
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_connections.firm_id
      and m.role = 'firm_admin'
  )
);

-- ----------------------------
-- TOKENS (apenas staff)
-- ----------------------------
drop policy if exists "tokens_staff_select" on azul.integration_tokens;
create policy "tokens_staff_select"
on azul.integration_tokens
for select
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_tokens.connection_id
  )
);

drop policy if exists "tokens_staff_write" on azul.integration_tokens;
create policy "tokens_staff_write"
on azul.integration_tokens
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_tokens.connection_id
  )
);

drop policy if exists "tokens_staff_update" on azul.integration_tokens;
create policy "tokens_staff_update"
on azul.integration_tokens
for update
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_tokens.connection_id
  )
)
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_tokens.connection_id
  )
);

drop policy if exists "tokens_staff_delete" on azul.integration_tokens;
create policy "tokens_staff_delete"
on azul.integration_tokens
for delete
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_tokens.connection_id
  )
);

-- ----------------------------
-- WEBHOOKS (apenas staff)
-- ----------------------------
drop policy if exists "webhooks_staff_select" on azul.integration_webhooks;
create policy "webhooks_staff_select"
on azul.integration_webhooks
for select
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_webhooks.connection_id
  )
);

drop policy if exists "webhooks_staff_write" on azul.integration_webhooks;
create policy "webhooks_staff_write"
on azul.integration_webhooks
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_webhooks.connection_id
  )
);

drop policy if exists "webhooks_staff_update" on azul.integration_webhooks;
create policy "webhooks_staff_update"
on azul.integration_webhooks
for update
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_webhooks.connection_id
  )
)
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_webhooks.connection_id
  )
);

drop policy if exists "webhooks_staff_delete" on azul.integration_webhooks;
create policy "webhooks_staff_delete"
on azul.integration_webhooks
for delete
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_webhooks.connection_id
  )
);

-- ----------------------------
-- JOBS (staff)
-- ----------------------------
drop policy if exists "jobs_staff_select" on azul.integration_jobs;
create policy "jobs_staff_select"
on azul.integration_jobs
for select
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_jobs.connection_id
  )
);

drop policy if exists "jobs_staff_write" on azul.integration_jobs;
create policy "jobs_staff_write"
on azul.integration_jobs
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_jobs.connection_id
  )
);

drop policy if exists "jobs_staff_update" on azul.integration_jobs;
create policy "jobs_staff_update"
on azul.integration_jobs
for update
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_jobs.connection_id
  )
)
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_jobs.connection_id
  )
);

drop policy if exists "jobs_staff_delete" on azul.integration_jobs;
create policy "jobs_staff_delete"
on azul.integration_jobs
for delete
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_jobs.connection_id
  )
);

-- ----------------------------
-- ENTITIES MAP (staff)
-- ----------------------------
drop policy if exists "emap_staff_select" on azul.integration_entities_map;
create policy "emap_staff_select"
on azul.integration_entities_map
for select
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_entities_map.connection_id
  )
);

drop policy if exists "emap_staff_insert" on azul.integration_entities_map;
create policy "emap_staff_insert"
on azul.integration_entities_map
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_entities_map.connection_id
  )
);

drop policy if exists "emap_staff_update" on azul.integration_entities_map;
create policy "emap_staff_update"
on azul.integration_entities_map
for update
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_entities_map.connection_id
  )
)
with check (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_entities_map.connection_id
  )
);

drop policy if exists "emap_staff_delete" on azul.integration_entities_map;
create policy "emap_staff_delete"
on azul.integration_entities_map
for delete
to authenticated
using (
  exists (
    select 1
    from azul.integration_connections c
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = c.firm_id
     and m.role in ('firm_admin','firm_staff')
    where c.id = integration_entities_map.connection_id
  )
);

-- ----------------------------
-- MESSAGES (Komunic)
-- ----------------------------
drop policy if exists "msgs_select_by_scope" on azul.integration_messages;
create policy "msgs_select_by_scope"
on azul.integration_messages
for select
to authenticated
using (
  -- staff da firm vê tudo
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_messages.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or
  (
    -- cliente vê mensagens do seu client_id (inbound & outbound)
    integration_messages.client_id is not null
    and exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = integration_messages.client_id
    )
  )
);

drop policy if exists "msgs_insert_staff_outbound" on azul.integration_messages;
create policy "msgs_insert_staff_outbound"
on azul.integration_messages
for insert
to authenticated
with check (
  -- apenas staff pode criar mensagens (geralmente outbound)
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_messages.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "msgs_update_staff" on azul.integration_messages;
create policy "msgs_update_staff"
on azul.integration_messages
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_messages.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_messages.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "msgs_delete_admin" on azul.integration_messages;
create policy "msgs_delete_admin"
on azul.integration_messages
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_messages.firm_id
      and m.role = 'firm_admin'
  )
);
