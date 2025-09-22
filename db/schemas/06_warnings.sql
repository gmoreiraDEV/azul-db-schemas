-- =========================================================
-- Schema: Warnings / Recados (avisos internos e para clientes)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql
-- =========================================================

-- 0) Garantir UNIQUE composta em clients (id, firm_id) para suportar FK composta opcional
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
  if not exists (select 1 from pg_type where typname = 'warning_severity_enum') then
    create type azul.warning_severity_enum as enum ('info','warning','critical');
  end if;

  if not exists (select 1 from pg_type where typname = 'warning_status_enum') then
    create type azul.warning_status_enum as enum ('draft','scheduled','published','archived');
  end if;

  if not exists (select 1 from pg_type where typname = 'warning_audience_enum') then
    create type azul.warning_audience_enum as enum ('staff','client','both');
  end if;

  if not exists (select 1 from pg_type where typname = 'warning_channel_enum') then
    create type azul.warning_channel_enum as enum ('web','email','sms','push','komunic');
  end if;
end$$;

-- =========================================================
-- 2) Tabela principal: warnings (recados/avisos)
-- =========================================================
create table if not exists azul.warnings (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id) on delete cascade,
  client_id uuid,  -- opcional: aviso direcionado a um cliente específico (senão é geral da firm)

  title text not null,
  body  text not null,

  severity azul.warning_severity_enum not null default 'info',
  status   azul.warning_status_enum   not null default 'draft',
  audience azul.warning_audience_enum not null default 'both',

  requires_ack boolean not null default false, -- exige confirmação de ciência do usuário
  pinned       boolean not null default false, -- fixado no topo

  channel azul.warning_channel_enum[] not null default '{web}', -- canais pretendidos (informativo)

  -- janela de exibição
  start_at timestamptz,   -- quando começa a valer (para scheduled/published)
  end_at   timestamptz,   -- quando deixa de valer
  constraint warning_time_range_chk check (
    start_at is null or end_at is null or end_at >= start_at
  ),

  -- publicação
  published_at timestamptz,
  published_by uuid references azul.profiles(id) on delete set null,

  -- metadados úteis
  action_label text,  -- texto do botão/cta
  action_url   text,  -- link externo (se houver)
  metadata jsonb not null default '{}'::jsonb,

  created_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- se published, published_at deve existir
  constraint warnings_published_chk check (
    (status <> 'published') or (published_at is not null)
  )
);

-- FK composta: (client_id, firm_id) -> clients(id, firm_id); ignora quando client_id é null
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'warnings_client_firm_fk'
      and conrelid = 'azul.warnings'::regclass
  ) then
    alter table azul.warnings
      add constraint warnings_client_firm_fk
      foreign key (client_id, firm_id)
      references azul.clients(id, firm_id)
      on delete cascade;
  end if;
end$$;

create index if not exists idx_warnings_firm      on azul.warnings(firm_id);
create index if not exists idx_warnings_client    on azul.warnings(client_id);
create index if not exists idx_warnings_status    on azul.warnings(status);
create index if not exists idx_warnings_window    on azul.warnings(start_at, end_at);
create index if not exists idx_warnings_pinned    on azul.warnings(pinned);
create index if not exists idx_warnings_severity  on azul.warnings(severity);
create index if not exists idx_warnings_audience  on azul.warnings(audience);

create trigger trg_warnings_updated_at
before update on azul.warnings
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Acknowledgements (ciência do usuário)
-- =========================================================
create table if not exists azul.warning_acknowledgements (
  warning_id uuid not null references azul.warnings(id) on delete cascade,
  user_id    uuid not null references azul.profiles(id) on delete cascade,
  ack_at     timestamptz not null default now(),
  details    jsonb not null default '{}'::jsonb,
  primary key (warning_id, user_id)
);

create index if not exists idx_warning_acks_user on azul.warning_acknowledgements(user_id);

-- =========================================================
-- 4) RLS
-- =========================================================
alter table azul.warnings                 enable row level security;
alter table azul.warning_acknowledgements enable row level security;

-- ----------------------------
-- Warnings: SELECT
-- ----------------------------

-- Equipe da firm pode ver TODOS os avisos da própria firm (qualquer status)
drop policy if exists "warnings_select_staff_all" on azul.warnings;
create policy "warnings_select_staff_all"
on azul.warnings
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.warnings.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- Clientes podem ver avisos PUBLICADOS e dentro da janela, destinados:
--  a) especificamente ao seu client_id, OU
--  b) a todos (client_id IS NULL) e audience in ('client','both')
drop policy if exists "warnings_select_client_published" on azul.warnings;
create policy "warnings_select_client_published"
on azul.warnings
for select
to authenticated
using (
  -- é usuário de algum client da mesma firm do aviso
  exists (
    select 1
    from azul.memberships m2
    join azul.clients c on c.id = m2.client_id
    where m2.user_id = auth.uid()
      and c.firm_id = azul.warnings.firm_id
  )
  and status = 'published'
  and (start_at is null or start_at <= now())
  and (end_at   is null or end_at   >= now())
  and (
    exists ( -- aviso específico para o client do usuário
      select 1
      from azul.memberships m3
      where m3.user_id = auth.uid()
        and m3.client_id = azul.warnings.client_id
    )
    or ( -- aviso geral da firm para clientes
      azul.warnings.client_id is null
      and audience in ('client','both')
    )
  )
);

-- ----------------------------
-- Warnings: INSERT / UPDATE / DELETE (apenas equipe)
-- ----------------------------
drop policy if exists "warnings_insert_staff" on azul.warnings;
create policy "warnings_insert_staff"
on azul.warnings
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.warnings.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "warnings_update_staff" on azul.warnings;
create policy "warnings_update_staff"
on azul.warnings
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.warnings.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.warnings.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "warnings_delete_admin" on azul.warnings;
create policy "warnings_delete_admin"
on azul.warnings
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.warnings.firm_id
      and m.role = 'firm_admin'
  )
);

-- ----------------------------
-- Acknowledgements: SELECT
-- ----------------------------

-- Staff da firm do aviso vê todos os acks do aviso
drop policy if exists "warning_acks_select_staff" on azul.warning_acknowledgements;
create policy "warning_acks_select_staff"
on azul.warning_acknowledgements
for select
to authenticated
using (
  exists (
    select 1
    from azul.warnings w
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = w.firm_id
     and m.role in ('firm_admin','firm_staff')
    where w.id = azul.warning_acknowledgements.warning_id
  )
);

-- O próprio usuário pode ver seus acks (independente de staff/cliente)
drop policy if exists "warning_acks_select_self" on azul.warning_acknowledgements;
create policy "warning_acks_select_self"
on azul.warning_acknowledgements
for select
to authenticated
using (user_id = auth.uid());

-- ----------------------------
-- Acknowledgements: INSERT
-- ----------------------------

-- Qualquer usuário que possa ver o aviso pode registrar ciência, mas só por si mesmo (user_id = auth.uid()).
drop policy if exists "warning_acks_insert_by_readers" on azul.warning_acknowledgements;
create policy "warning_acks_insert_by_readers"
on azul.warning_acknowledgements
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from azul.warnings w
    where w.id = azul.warning_acknowledgements.warning_id
      and (
        -- staff da firm do aviso
        exists (
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = w.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          -- cliente com acesso ao aviso publicado e dentro da janela
          exists (
            select 1
            from azul.memberships m2
            join azul.clients c on c.id = m2.client_id
            where m2.user_id = auth.uid()
              and c.firm_id = w.firm_id
          )
          and w.status = 'published'
          and (w.start_at is null or w.start_at <= now())
          and (w.end_at   is null or w.end_at   >= now())
          and (
            exists (
              select 1 from azul.memberships m3
              where m3.user_id = auth.uid()
                and m3.client_id = w.client_id
            )
            or (w.client_id is null and w.audience in ('client','both'))
          )
        )
      )
  )
);

-- ----------------------------
-- Acknowledgements: DELETE
-- ----------------------------

-- firm_admin pode remover acknowledgements; o próprio usuário também pode remover o seu, se desejado
drop policy if exists "warning_acks_delete_admin_or_self" on azul.warning_acknowledgements;
create policy "warning_acks_delete_admin_or_self"
on azul.warning_acknowledgements
for delete
to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1
    from azul.warnings w
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = w.firm_id
     and m.role = 'firm_admin'
    where w.id = azul.warning_acknowledgements.warning_id
  )
);
