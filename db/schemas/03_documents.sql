-- =========================================================
-- Schema: Documents (documentos por cliente + versionamento)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql
-- =========================================================

-- 0) Garantir UNIQUE composta em clients (id, firm_id) para suportar FK composta
do $$
begin
  if not exists (
    select 1
    from pg_constraint
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

-- =========================================================
-- 2) Tipos de Documento
-- =========================================================
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

-- =========================================================
-- 3) Documentos (cabeçalho por cliente)
-- =========================================================
create table if not exists azul.documents (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid not null,
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
  latest_version_id uuid,               -- referência "solta" (sem FK) para evitar ciclo
  created_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint documents_comp_month_chk check (competence_month is null or (competence_month between 1 and 12))
);

-- FK composta para garantir que o client pertença à firm
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'documents_client_firm_fk'
      and conrelid = 'azul.documents'::regclass
  ) then
    alter table azul.documents
      add constraint documents_client_firm_fk
      foreign key (client_id, firm_id)
      references azul.clients(id, firm_id)
      on delete cascade;
  end if;
end$$;

create index if not exists idx_documents_firm       on azul.documents(firm_id);
create index if not exists idx_documents_client     on azul.documents(client_id);
create index if not exists idx_documents_type       on azul.documents(type_id);
create index if not exists idx_documents_status     on azul.documents(status);
create index if not exists idx_documents_visibility on azul.documents(is_visible_to_client);

create trigger trg_documents_updated_at
before update on azul.documents
for each row execute function azul.set_updated_at();

-- =========================================================
-- 4) Versões de Documento (arquivos)
-- =========================================================
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

create index if not exists idx_document_versions_doc         on azul.document_versions(document_id);
create index if not exists idx_document_versions_uploaded_by on azul.document_versions(uploaded_by);

-- Auto-incremento do version_no
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

-- Atualiza latest_version_id no documents após cada nova versão
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

-- =========================================================
-- 5) (Opcional) Eventos/Logs de documento (view/download/ack)
-- =========================================================
create table if not exists azul.document_events (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references azul.documents(id) on delete cascade,
  user_id uuid not null references azul.profiles(id) on delete cascade,
  event_type text not null check (event_type in ('view','download','acknowledge')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_document_events_doc  on azul.document_events(document_id);
create index if not exists idx_document_events_user on azul.document_events(user_id);

-- =========================================================
-- 6) RLS
-- =========================================================

-- Ativar RLS
alter table azul.document_types     enable row level security;
alter table azul.documents          enable row level security;
alter table azul.document_versions  enable row level security;
alter table azul.document_events    enable row level security;

-- ---------------------------------------------------------
-- DOCUMENT_TYPES
-- SELECT: equipe da firm + clientes vinculados a qualquer client dessa firm
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
  or exists ( -- clientes cuja client.firm_id = document_types.firm_id
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
--  - cliente vê seus docs se: is_visible_to_client = true OU (origin='client' e created_by = auth.uid())
drop policy if exists "documents_select_by_scope" on azul.documents;
create policy "documents_select_by_scope"
on azul.documents
for select
to authenticated
using (
  -- staff da firm
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.documents.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or
  (
    -- usuário do cliente
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.documents.client_id
    )
    and (
      is_visible_to_client = true
      or (origin = 'client' and created_by = auth.uid())
    )
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
  )
);

-- UPDATE:
--  - equipe da firm pode atualizar qualquer documento da firm
--  - cliente pode editar APENAS documentos criados por ele (origin='client' e created_by=auth.uid()) e enquanto status em ('draft','submitted')
drop policy if exists "documents_update_by_scope" on azul.documents;
create policy "documents_update_by_scope"
on azul.documents
for update
to authenticated
using (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.documents.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    -- cliente dono do doc
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.documents.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status in ('draft','submitted')
  )
)
with check (
  -- integridade firm↔client garantida pela FK composta
  true
);

-- DELETE:
--  - firm_admin pode excluir
--  - cliente pode excluir documento que ele mesmo criou (origin='client', created_by=auth.uid(), status='draft')
drop policy if exists "documents_delete_by_scope" on azul.documents;
create policy "documents_delete_by_scope"
on azul.documents
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.documents.firm_id
      and m.role = 'firm_admin'
  )
  or (
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.documents.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status = 'draft'
  )
);

-- ---------------------------------------------------------
-- DOCUMENT_VERSIONS

-- SELECT: quem pode ver o documento pai pode ver suas versões
drop policy if exists "document_versions_select_by_parent" on azul.document_versions;
create policy "document_versions_select_by_parent"
on azul.document_versions
for select
to authenticated
using (
  exists (
    select 1
    from azul.documents d
    where d.id = azul.document_versions.document_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = d.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          exists ( -- cliente com acesso
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = d.client_id
          )
          and (
            d.is_visible_to_client = true
            or (d.origin = 'client' and d.created_by = auth.uid())
          )
        )
      )
  )
);

-- INSERT:
--  - equipe pode subir nova versão de qualquer documento da sua firm
--  - cliente pode subir nova versão SOMENTE do documento que ele criou (origin='client', created_by=auth.uid()) e enquanto status em ('draft','submitted')
drop policy if exists "document_versions_insert_by_scope" on azul.document_versions;
create policy "document_versions_insert_by_scope"
on azul.document_versions
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.documents d
    where d.id = azul.document_versions.document_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = d.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or ( -- cliente dono do doc
          exists (
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = d.client_id
          )
          and d.origin = 'client'
          and d.created_by = auth.uid()
          and d.status in ('draft','submitted')
        )
      )
  )
);

-- UPDATE: bloqueado (versões são imutáveis)
drop policy if exists "document_versions_update_none" on azul.document_versions;
create policy "document_versions_update_none"
on azul.document_versions
for update
to authenticated
using (false)
with check (false);

-- DELETE: apenas firm_admin (exceções)
drop policy if exists "document_versions_delete_admin" on azul.document_versions;
create policy "document_versions_delete_admin"
on azul.document_versions
for delete
to authenticated
using (
  exists (
    select 1
    from azul.documents d
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = d.firm_id
     and m.role = 'firm_admin'
    where d.id = azul.document_versions.document_id
  )
);

-- ---------------------------------------------------------
-- DOCUMENT_EVENTS (logs)
-- SELECT: equipe da firm (todos os eventos do documento) + cliente (eventos de docs que ele pode ver)
drop policy if exists "document_events_select_by_scope" on azul.document_events;
create policy "document_events_select_by_scope"
on azul.document_events
for select
to authenticated
using (
  exists (
    select 1
    from azul.documents d
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = d.firm_id
     and m.role in ('firm_admin','firm_staff')
    where d.id = azul.document_events.document_id
  )
  or exists (
    select 1
    from azul.documents d2
    join azul.memberships m2
      on m2.user_id = auth.uid()
     and m2.client_id = d2.client_id
    where d2.id = azul.document_events.document_id
      and (
        d2.is_visible_to_client = true
        or (d2.origin = 'client' and d2.created_by = auth.uid())
      )
  )
);

-- INSERT: qualquer usuário autenticado que consiga ler o documento pode registrar evento
drop policy if exists "document_events_insert_by_readers" on azul.document_events;
create policy "document_events_insert_by_readers"
on azul.document_events
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.documents d
    where d.id = azul.document_events.document_id
      and (
        exists (
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = d.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          exists (
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = d.client_id
          )
          and (
            d.is_visible_to_client = true
            or (d.origin = 'client' and d.created_by = auth.uid())
          )
        )
      )
  )
);

-- UPDATE/DELETE: bloqueado por padrão
drop policy if exists "document_events_update_none" on azul.document_events;
create policy "document_events_update_none"
on azul.document_events
for update
to authenticated
using (false)
with check (false);

drop policy if exists "document_events_delete_none" on azul.document_events;
create policy "document_events_delete_none"
on azul.document_events
for delete
to authenticated
using (false);
