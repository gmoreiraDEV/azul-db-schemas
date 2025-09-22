-- =========================================================
-- Schema: Certificados Digitais (e-CNPJ / e-CPF / A1 / A3)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql (e UNIQUE composta em clients)
-- =========================================================

-- 0) Garantir UNIQUE composta em clients (id, firm_id) para FK composta
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
  if not exists (select 1 from pg_type where typname = 'cert_type_enum') then
    create type azul.cert_type_enum as enum ('A1','A3');
  end if;

  if not exists (select 1 from pg_type where typname = 'cert_token_enum') then
    create type azul.cert_token_enum as enum ('file','smartcard','token_usb','cloud');
  end if;

  if not exists (select 1 from pg_type where typname = 'cert_status_enum') then
    create type azul.cert_status_enum as enum (
      'requested',  -- solicitado (a emitir/renovar)
      'issued',     -- emitido
      'valid',      -- válido (em uso)
      'expiring',   -- próximo do vencimento
      'expired',    -- vencido
      'revoked'     -- revogado
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'cert_origin_enum') then
    create type azul.cert_origin_enum as enum ('firm','client'); -- criado pela contabilidade ou pelo cliente
  end if;

  if not exists (select 1 from pg_type where typname = 'cert_attachment_kind_enum') then
    create type azul.cert_attachment_kind_enum as enum (
      'certificate_file',   -- o .pfx/.p12 (A1) ou arquivo de configuração
      'power_of_attorney',  -- procuração
      'id_document',        -- documentos de identidade
      'other'               -- outros
    );
  end if;
end$$;

-- =========================================================
-- 2) Tabela principal: digital_certificates
-- =========================================================
create table if not exists azul.digital_certificates (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id)   on delete cascade,
  client_id uuid not null,                             -- FK composta abaixo

  origin azul.cert_origin_enum not null default 'firm',
  status azul.cert_status_enum not null default 'requested',

  -- identificação
  holder_name   text,            -- nome do titular (se diferente do client)
  holder_tax_id text,            -- CPF/CNPJ do titular (se diferente do client)
  cert_type     azul.cert_type_enum not null,     -- A1/A3
  token_kind    azul.cert_token_enum not null default 'file',

  serial_number text,                                  -- pode ser nulo até emissão
  issuer        text,
  subject       text,

  valid_from date,
  valid_to   date,
  constraint valid_range_chk check (
    valid_from is null or valid_to is null or valid_to >= valid_from
  ),

  -- armazenamento (A1)
  storage_path text,      -- caminho no Supabase Storage (se A1/arquivo)
  has_password boolean not null default false,
  password_hint text,     -- dica da senha (não a senha)
  secret_ref text,        -- referência no gestor de segredos (ex.: Vault/KMS)

  -- responsáveis & contato
  responsible_id uuid references azul.profiles(id) on delete set null, -- responsável interno
  contact_email text,
  contact_phone text,

  -- renovação & lembretes
  auto_renew boolean not null default false,
  reminder_days int[] not null default '{60,30,15,7,1}'::int[],
  next_reminder_at timestamptz,

  -- integração com provedores (opcional)
  provider_name text,
  provider_ref  text,

  -- controle
  created_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- FK composta: garante client pertence à firm
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'digital_certificates_client_firm_fk'
      and conrelid = 'azul.digital_certificates'::regclass
  ) then
    alter table azul.digital_certificates
      add constraint digital_certificates_client_firm_fk
      foreign key (client_id, firm_id)
      references azul.clients(id, firm_id)
      on delete cascade;
  end if;
end$$;

-- Serial único quando informado
create unique index if not exists uidx_digital_certificates_serial
  on azul.digital_certificates(serial_number)
  where serial_number is not null;

create index if not exists idx_digital_certificates_firm    on azul.digital_certificates(firm_id);
create index if not exists idx_digital_certificates_client  on azul.digital_certificates(client_id);
create index if not exists idx_digital_certificates_status  on azul.digital_certificates(status);
create index if not exists idx_digital_certificates_validto on azul.digital_certificates(valid_to);

create trigger trg_digital_certificates_updated_at
before update on azul.digital_certificates
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Anexos do certificado (arquivos auxiliares)
-- =========================================================
create table if not exists azul.certificate_attachments (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null references azul.digital_certificates(id) on delete cascade,

  kind azul.cert_attachment_kind_enum not null default 'other',
  storage_path text not null,      -- caminho no Supabase Storage
  mime_type text,
  size_bytes bigint,
  notes text,

  uploaded_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_certificate_attachments_cert on azul.certificate_attachments(certificate_id);
create index if not exists idx_certificate_attachments_kind on azul.certificate_attachments(kind);

-- =========================================================
-- 4) Eventos/Logs do certificado
-- =========================================================
create table if not exists azul.certificate_events (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null references azul.digital_certificates(id) on delete cascade,
  user_id uuid not null references azul.profiles(id) on delete cascade,
  event_type text not null check (event_type in (
    'request','issue','renew','revoke','expire','notify','view','download','upload'
  )),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_certificate_events_cert on azul.certificate_events(certificate_id);
create index if not exists idx_certificate_events_user on azul.certificate_events(user_id);
create index if not exists idx_certificate_events_type on azul.certificate_events(event_type);

-- =========================================================
-- 5) (Opcional) Função para atualizar status para 'expiring'
-- =========================================================
create or replace function azul.flag_expiring_certificates(days_before int default 30)
returns void
language plpgsql
as $$
begin
  update azul.digital_certificates
     set status = case when status in ('valid','issued') then 'expiring' else status end,
         updated_at = now()
   where valid_to is not null
     and valid_to <= (current_date + make_interval(days => days_before))
     and status in ('valid','issued');
end$$;

-- =========================================================
-- 6) RLS
-- =========================================================
alter table azul.digital_certificates  enable row level security;
alter table azul.certificate_attachments enable row level security;
alter table azul.certificate_events     enable row level security;

-- ----------------------------
-- DIGITAL_CERTIFICATES
-- ----------------------------

-- SELECT: equipe da firm vê tudo; cliente vê os seus certificados
drop policy if exists "certs_select_by_scope" on azul.digital_certificates;
create policy "certs_select_by_scope"
on azul.digital_certificates
for select
to authenticated
using (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.digital_certificates.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or exists ( -- cliente
    select 1 from azul.memberships m2
    where m2.user_id = auth.uid()
      and m2.client_id = azul.digital_certificates.client_id
  )
);

-- INSERT:
--  - equipe da firm pode inserir
--  - cliente pode solicitar (origin='client', status='requested', created_by=auth.uid())
drop policy if exists "certs_insert_by_scope" on azul.digital_certificates;
create policy "certs_insert_by_scope"
on azul.digital_certificates
for insert
to authenticated
with check (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.digital_certificates.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    exists ( -- cliente
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.digital_certificates.client_id
    )
    and origin = 'client'
    and status = 'requested'
    and created_by = auth.uid()
  )
);

-- UPDATE:
--  - equipe pode atualizar qualquer certificado da firm
--  - cliente pode editar somente registros criados por ele (origin='client') enquanto status='requested'
drop policy if exists "certs_update_by_scope" on azul.digital_certificates;
create policy "certs_update_by_scope"
on azul.digital_certificates
for update
to authenticated
using (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.digital_certificates.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    exists ( -- cliente dono
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.digital_certificates.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status = 'requested'
  )
)
with check (true);

-- DELETE:
--  - firm_admin pode excluir
--  - cliente pode excluir item que ele criou, enquanto status='requested'
drop policy if exists "certs_delete_by_scope" on azul.digital_certificates;
create policy "certs_delete_by_scope"
on azul.digital_certificates
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.digital_certificates.firm_id
      and m.role = 'firm_admin'
  )
  or (
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.digital_certificates.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status = 'requested'
  )
);

-- ----------------------------
-- CERTIFICATE_ATTACHMENTS
-- ----------------------------

-- SELECT: quem pode ver o certificado pai pode ver os anexos
drop policy if exists "cert_attachments_select_by_parent" on azul.certificate_attachments;
create policy "cert_attachments_select_by_parent"
on azul.certificate_attachments
for select
to authenticated
using (
  exists (
    select 1
    from azul.digital_certificates dc
    where dc.id = azul.certificate_attachments.certificate_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = dc.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or exists ( -- cliente
          select 1 from azul.memberships m2
          where m2.user_id = auth.uid()
            and m2.client_id = dc.client_id
        )
      )
  )
);

-- INSERT:
--  - equipe pode anexar qualquer arquivo do certificado
--  - cliente pode anexar somente quando for criador do certificado (origin='client', status='requested')
drop policy if exists "cert_attachments_insert_by_scope" on azul.certificate_attachments;
create policy "cert_attachments_insert_by_scope"
on azul.certificate_attachments
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.digital_certificates dc
    where dc.id = azul.certificate_attachments.certificate_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = dc.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          exists ( -- cliente criador
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = dc.client_id
          )
          and dc.origin = 'client'
          and dc.created_by = auth.uid()
          and dc.status = 'requested'
        )
      )
  )
);

-- UPDATE: normalmente anexos são imutáveis. Bloqueado.
drop policy if exists "cert_attachments_update_none" on azul.certificate_attachments;
create policy "cert_attachments_update_none"
on azul.certificate_attachments
for update
to authenticated
using (false)
with check (false);

-- DELETE:
--  - firm_admin pode excluir anexos
drop policy if exists "cert_attachments_delete_admin" on azul.certificate_attachments;
create policy "cert_attachments_delete_admin"
on azul.certificate_attachments
for delete
to authenticated
using (
  exists (
    select 1
    from azul.digital_certificates dc
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = dc.firm_id
     and m.role = 'firm_admin'
    where dc.id = azul.certificate_attachments.certificate_id
  )
);

-- ----------------------------
-- CERTIFICATE_EVENTS
-- ----------------------------

-- SELECT: equipe da firm ou cliente do certificado
drop policy if exists "cert_events_select_by_scope" on azul.certificate_events;
create policy "cert_events_select_by_scope"
on azul.certificate_events
for select
to authenticated
using (
  exists (
    select 1
    from azul.digital_certificates dc
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = dc.firm_id
     and m.role in ('firm_admin','firm_staff')
    where dc.id = azul.certificate_events.certificate_id
  )
  or exists (
    select 1
    from azul.digital_certificates dc2
    join azul.memberships m2
      on m2.user_id = auth.uid()
     and m2.client_id = dc2.client_id
    where dc2.id = azul.certificate_events.certificate_id
  )
);

-- INSERT: qualquer usuário que tenha acesso de leitura ao certificado
drop policy if exists "cert_events_insert_by_readers" on azul.certificate_events;
create policy "cert_events_insert_by_readers"
on azul.certificate_events
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.digital_certificates dc
    where dc.id = azul.certificate_events.certificate_id
      and (
        exists (
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = dc.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or exists (
          select 1 from azul.memberships m2
          where m2.user_id = auth.uid()
            and m2.client_id = dc.client_id
        )
      )
  )
);

-- UPDATE/DELETE: bloqueado por padrão
drop policy if exists "cert_events_update_none" on azul.certificate_events;
create policy "cert_events_update_none"
on azul.certificate_events
for update
to authenticated
using (false)
with check (false);

drop policy if exists "cert_events_delete_none" on azul.certificate_events;
create policy "cert_events_delete_none"
on azul.certificate_events
for delete
to authenticated
using (false);
