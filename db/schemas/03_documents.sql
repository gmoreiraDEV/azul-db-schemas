-- =========================================================
-- Schema: Documents (documentos por cliente + versionamento)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql
-- =========================================================

-- 1) Enums
do $$
begin
  if not exists (select 1 from pg_type where typname = 'doc_status_enum') then
    create type azul.doc_status_enum as enum (
      'draft',       -- rascunho (interno ou do cliente)
      'submitted',   -- enviado pelo cliente para análise
      'available',   -- disponível/entregue ao cliente
      'archived'     -- arquivado
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'doc_origin_enum') then
    create type azul.doc_origin_enum as enum (
      'firm',        -- criado pela contabilidade
      'client'       -- enviado pelo cliente
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'doc_category_enum') then
    create type azul.doc_category_enum as enum (
      'fiscal',
      'dp',
      'contabil',
      'juridico',
      'comercial',
      'outros'
    );
  end if;
end$$;

-- 2) Tipos de Documento
create table if not exists azul.document_types (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  name text not null,
  slug text not null,
  category azul.doc_category_enum not null default 'outros',
  description text,
  allow_client_upload boolean not null default false,  -- permite cliente enviar este tipo
  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint document_types_slug_chk check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint document_types_unique_slug_per_firm unique (firm_id, slug)
);

create index if not exists idx_document_types_firm on azul.document_types(firm_id);

create trigger trg_document_types_updated_at
before update on azul.document_types
for each row execute function azul.set_updated_at();

-- 3) Documentos (cabecalho por cliente)
create table if not exists azul.documents (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id)   on delete cascade,
  client_id uuid not null references azul.clients(id) on delete cascade,
  type_id   uuid not null references azul.document_types(id) on delete restrict,

  title text not null,
  description text,
  status azul.doc_status_enum not null default 'available',
  origin azul.doc_origin_enum not null default 'firm',
  is_visible_to_client boolean not null default true,

  -- Competência/Período (opcional)
  competence_year  int,
  competence_month int,
  due_date date,
  issue_date date,

  -- controle
  latest_version_id uuid, -- ref para azul.document_versions.id
  created_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint documents_comp_month_chk check (competence_month is null or (competence_month between 1 and 12)),
  constraint documents_client_firm_consistency check (
    exists (
      select 1 from azul.clients c
      where c.id = client_id and c.firm_id = firm_id
    )
  )
);

create index if not exists idx_documents_firm on azul.documents(firm_id);
create index if not exists idx_documents_client on azul.documents(client_id);
create index if not exists idx_documents_type on azul.documents(type_id);
create index if not exists idx_documents_status on azul.documents(status);
create index if not exists idx_documents_visibility on azul.documents(is_visible_to_client);

create trigger trg_documents_updated_at
before update on azul.documents
for each row execute function azul.set_updated_at();

-- 4) Versões de Documento (arquivos)
create table if not exists azul.document_versions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references azul.documents(id) on delete cascade,

  version_no int not null,
  storage_path text,     -- caminho no Supabase Storage (ex: documents/<firm>/<client>/<doc>/<file>)
  external_url text,     -- opcional: URL externa
  mime_type text,
  size_bytes bigint,
  checksum text,         -- opcional: sha256/etag
  notes text,

  uploaded_by uuid not null references azul.profiles(id) on delete restrict,
  uploaded_at timestamptz not null default now(),

  constraint document_versions_unique_per_doc unique (document_id, version_no)
);

create index if not exists idx_document_versions_doc on azul.document_versions(document_id);
create index if not exists idx_document_versions_uploaded_by on azul.document_versions(uploaded_by);

-- 4.1) Trigger: auto-incremento de version_no
create or replace function azul.document_versions_next_version_no()
returns trigger as $$
declare
  next_no int;
begin
  if new.version_no is not null then
    return new;
  end if;

  select coalesce(max(version_no), 0) + 1 into next_no
  from azul.document_versions
  where document_id = new.document_id;

  new.version_no = next_no;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_document_versions_next_no on azul.document_versions;
create trigger trg_document_versions_next_no
before insert on azul.document_versions
for each row execute function azul.document_versions_next_version_no();

-- 4.2) Trigger: atualizar latest_version_id no documents
create or replace function azul.document_versions_bump_latest()
returns trigger as $$
begin
  update azul.documents
     set latest_version_id = new.id,
         updated_at = now()
   where id = new.document_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_document_versions_bump_latest on azul.document_versions;
create trigger trg_document_versions_bump_latest
after insert on azul.document_versions
for each row execute function azul.document_versions_bump_latest();

-- 5) (Opcional) Eventos/Logs de documento (view/download/ack)
-- Mantém histórico de interações dos usuários com o documento
create table if not exists azul.document_events (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references azul.documents(id) on delete cascade,
  user_id uuid not null references azul.profiles(id) on delete cascade,
  event_type text not null check (event_type in ('view','download','acknowledge')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_document_events_doc on azul.document_events(document_id);
create index if not exists idx_document_events_user on azul.document_events(user_id);

-- =========================================================
-- RLS
-- =========================================================

-- Ativar RLS
alter table azul.document_types   enable row level security;
alter table azul.documents        enable row level security;
alter table azul.document_versions enable row level security;
alter table azul.document_events  enable row level security;

-- ---------------------------------------------------------
-- DOCUMENT_TYPES
-- SELECT: equipe da firm e também usuários clientes vinculados a qualquer client dessa firm
drop policy if exists "document_types_read_by_scope" on azul.document_types;
create policy "document_types_read_by_scope"
on azul.document_types
for select
to authenticated
using (
  exists ( -- equipe da firm
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.document_types.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or exists ( -- clientes vinculados a um client cuja firm = document_types.firm_id
    select 1
    from azul.memberships m2
    join azul.clients c on c.id = m2.client_id
    where m2.user_id = auth.uid()
      and c.firm_id = azul.document_types.firm_id
  )
);

-- INSERT/UPDATE/DELETE: apenas equipe da firm
drop policy if exists "document_types_insert_staff" on azul.document_types;
create policy "document_types_insert_staff"
on azul.document_types
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.document_types.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "document_types_update_staff" on azul.document_types;
create policy "document_types_update_staff"
on azul.document_types
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.document_types.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.document_types.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "document_types_delete_admin" on azul.document_types;
create policy "document_types_delete_admin"
on azul.document_types
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.document_types.firm_id
      and m.role = 'firm_admin'
  )
);

-- ---------------------------------------------------------
-- DOCUMENTS
-- SELECT:
--  - equipe da firm vê tudo da firm
--  - cliente vê seus documentos quando (is_visible_to_client = true) ou quando foi ele quem criou (origin='client' e created_by = auth.uid())
drop policy if exists "documents_select_by_scope" on azul.documents;
create policy "documents_select_by_scope"
on azul.documents
for select
to authenticated
using (
  exists ( -- equipe do escritório
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.documents.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or exists ( -- usuário do cliente
    select 1 from azul.memberships m2
    where m2.user_id = auth.uid()
      and m2.client_id = azul.documents.client_id
  )
  and (
    -- se é cliente, precisa atender uma das regras abaixo; se é equipe, já passou na condição acima
    exists (
      select 1 from azul.memberships m3
      where m3.user_id = auth.uid()
        and m3.client_id = azul.documents.client_id
    ) = false
    or -- não é cliente (é staff), passa
    (true)
    or -- fallback reading
    (is_visible_to_client = true)
    or (origin = 'client' and created_by = auth.uid())
  )
);

-- INSERT:
--  - equipe da firm pode inserir para qualquer client da firm
--  - cliente pode inserir APENAS para o seu client_id, com origin='client', status='submitted' e created_by=auth.uid()
drop policy if exists "documents_insert_by_scope" on azul.documents;
create policy "documents_insert_by_scope"
on azul.documents
for insert
to authenticated
with check (
  (
    -- equipe do escritório
    exists (
      select 1 from azul.memberships m
      where m.user_id = auth.uid()
        and m.firm_id = azul.documents.firm_id
        and m.role in ('firm_admin','firm_staff')
    )
    and exists ( -- client pertence à firm
      select 1 from azul.clients c
      where c.id = azul.documents.client_id
        and c.firm_id = azul.documents.firm_id
    )
  )
  or
  (
    -- cliente enviando documento
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.documents.client_id
    )
    and origin = 'client'
    and status = 'submitted'
    and created_by = auth.uid()
    and exists ( -- firm_id consistente com o client
      select 1 from azul.clients c2
      where c2.id = azul.documents.client_id
        and c2.firm_id = azul.documents.firm_id
    )
  )
);

-- UPDATE:
--  - equipe da firm pode atualizar qualquer documento da firm
--  - cliente pode editar APENAS documentos criados por ele (origin='client' e created_by=auth.uid()) e enquanto status em ('dr_
