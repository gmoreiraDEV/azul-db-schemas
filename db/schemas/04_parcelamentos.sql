-- =========================================================
-- Schema: Parcelamentos (planos e parcelas)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql (e a UNIQUE composta em clients)
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
  if not exists (select 1 from pg_type where typname = 'plan_status_enum') then
    create type azul.plan_status_enum as enum (
      'draft',       -- rascunho (interno ou do cliente)
      'submitted',   -- enviado pelo cliente para análise
      'active',      -- plano vigente
      'completed',   -- todas as parcelas quitadas
      'canceled'     -- cancelado
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'plan_origin_enum') then
    create type azul.plan_origin_enum as enum (
      'firm',        -- criado pela contabilidade
      'client'       -- proposto/enviado pelo cliente
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'installment_status_enum') then
    create type azul.installment_status_enum as enum (
      'pending',
      'paid',
      'overdue',
      'canceled'
    );
  end if;
end$$;

-- =========================================================
-- 2) Planos de Parcelamento
-- =========================================================
create table if not exists azul.installment_plans (
  id uuid primary key default gen_random_uuid(),

  firm_id   uuid not null references azul.firms(id)   on delete cascade,
  client_id uuid not null,
  title text not null,                  -- ex.: "Refis ICMS 2025"
  description text,
  authority text,                       -- órgão/programa (ex.: "Receita Federal")
  tax_type text,                        -- ex.: "IRPJ", "INSS", "ISS", "ICMS", "DARF"
  reference_code text,                  -- nº do acordo/processo

  origin azul.plan_origin_enum not null default 'firm',
  status azul.plan_status_enum not null default 'draft',

  principal_amount numeric(14,2),       -- valor principal da dívida
  total_amount numeric(14,2),           -- valor total acordado
  down_payment_amount numeric(14,2),    -- entrada (opcional)
  interest_rate_percent numeric(7,4),   -- taxa (% a.m./a.a. - livre)
  fine_amount numeric(14,2),            -- multa fixa (opcional)

  start_date date,                      -- início do plano
  num_installments int check (num_installments is null or num_installments > 0),

  created_by uuid not null references azul.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- FK composta garante que o client pertence à firm
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'installment_plans_client_firm_fk'
      and conrelid = 'azul.installment_plans'::regclass
  ) then
    alter table azul.installment_plans
      add constraint installment_plans_client_firm_fk
      foreign key (client_id, firm_id)
      references azul.clients(id, firm_id)
      on delete cascade;
  end if;
end$$;

create index if not exists idx_installment_plans_firm   on azul.installment_plans(firm_id);
create index if not exists idx_installment_plans_client on azul.installment_plans(client_id);
create index if not exists idx_installment_plans_status on azul.installment_plans(status);
create index if not exists idx_installment_plans_start  on azul.installment_plans(start_date);

create trigger trg_installment_plans_updated_at
before update on azul.installment_plans
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Parcelas (itens do parcelamento)
-- =========================================================
create table if not exists azul.installment_items (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references azul.installment_plans(id) on delete cascade,

  seq_no int not null check (seq_no > 0),   -- nº da parcela (1..N)
  due_date date not null,
  amount numeric(14,2) not null check (amount > 0),

  status azul.installment_status_enum not null default 'pending',
  paid_amount numeric(14,2),
  paid_at timestamptz,
  payment_method text,                      -- ex.: "boleto", "pix", "cartao"
  external_payment_ref text,                -- id externo (Asaas etc.)
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint installment_items_paid_consistency check (
    (status <> 'paid')
    or (status = 'paid' and paid_at is not null and paid_amount is not null and paid_amount > 0)
  )
);

create unique index if not exists uidx_installment_items_seq
  on azul.installment_items(plan_id, seq_no);

create index if not exists idx_installment_items_due  on azul.installment_items(due_date);
create index if not exists idx_installment_items_stat on azul.installment_items(status);

create trigger trg_installment_items_updated_at
before update on azul.installment_items
for each row execute function azul.set_updated_at();

-- =========================================================
-- 4) (Opcional) Eventos/Logs (mudanças de status, comprovantes, etc.)
-- =========================================================
create table if not exists azul.installment_events (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references azul.installment_plans(id) on delete cascade,
  item_id uuid references azul.installment_items(id) on delete cascade,
  user_id uuid not null references azul.profiles(id) on delete cascade,
  event_type text not null check (event_type in (
    'create_plan','update_plan','activate_plan','complete_plan','cancel_plan',
    'create_item','update_item','delete_item',
    'mark_paid','mark_overdue','revert_payment'
  )),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_installment_events_plan on azul.installment_events(plan_id);
create index if not exists idx_installment_events_item on azul.installment_events(item_id);
create index if not exists idx_installment_events_user on azul.installment_events(user_id);

-- =========================================================
-- 5) Triggers utilitárias (recalcular status do plano)
-- =========================================================
create or replace function azul.recalc_plan_status(p_plan_id uuid)
returns void
language plpgsql
as $$
declare
  v_total int;
  v_paid int;
begin
  select count(*)::int, sum(case when status='paid' then 1 else 0 end)::int
    into v_total, v_paid
  from azul.installment_items
  where plan_id = p_plan_id;

  if v_total > 0 and v_paid = v_total then
    update azul.installment_plans
       set status = 'completed',
           updated_at = now()
     where id = p_plan_id
       and status <> 'completed';
  elsif v_total > 0 and v_paid < v_total then
    -- se estava 'completed' e voltou a ter parcela não paga, reativa para 'active'
    update azul.installment_plans
       set status = case when status in ('draft','submitted','canceled') then 'active' else status end,
           updated_at = now()
     where id = p_plan_id
       and status = 'completed';
  end if;
end$$;

create or replace function azul.installment_items_after_change()
returns trigger
language plpgsql
as $$
begin
  perform azul.recalc_plan_status(coalesce(new.plan_id, old.plan_id));
  return null;
end$$;

drop trigger if exists trg_installment_items_after_insert on azul.installment_items;
create trigger trg_installment_items_after_insert
after insert on azul.installment_items
for each row execute function azul.installment_items_after_change();

drop trigger if exists trg_installment_items_after_update on azul.installment_items;
create trigger trg_installment_items_after_update
after update on azul.installment_items
for each row execute function azul.installment_items_after_change();

drop trigger if exists trg_installment_items_after_delete on azul.installment_items;
create trigger trg_installment_items_after_delete
after delete on azul.installment_items
for each row execute function azul.installment_items_after_change();

-- =========================================================
-- 6) RLS
-- =========================================================
alter table azul.installment_plans  enable row level security;
alter table azul.installment_items  enable row level security;
alter table azul.installment_events enable row level security;

-- ----------------------------
-- INSTALLMENT_PLANS
-- ----------------------------

-- SELECT: equipe da firm ou usuários do cliente dono
drop policy if exists "plans_select_by_scope" on azul.installment_plans;
create policy "plans_select_by_scope"
on azul.installment_plans
for select
to authenticated
using (
  exists ( -- equipe do escritório
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.installment_plans.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or exists ( -- usuário cliente
    select 1 from azul.memberships m2
    where m2.user_id = auth.uid()
      and m2.client_id = azul.installment_plans.client_id
  )
);

-- INSERT: equipe da firm OU cliente (origin='client', status='submitted', created_by=auth.uid())
drop policy if exists "plans_insert_by_scope" on azul.installment_plans;
create policy "plans_insert_by_scope"
on azul.installment_plans
for insert
to authenticated
with check (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.installment_plans.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    exists ( -- cliente
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.installment_plans.client_id
    )
    and origin = 'client'
    and status = 'submitted'
    and created_by = auth.uid()
  )
);

-- UPDATE: equipe da firm OU cliente dono (origin='client', status in draft/submitted)
drop policy if exists "plans_update_by_scope" on azul.installment_plans;
create policy "plans_update_by_scope"
on azul.installment_plans
for update
to authenticated
using (
  exists ( -- equipe
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.installment_plans.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    exists ( -- cliente dono
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.installment_plans.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status in ('draft','submitted')
  )
)
with check (true);

-- DELETE: firm_admin OU cliente dono (origin='client' e status='draft')
drop policy if exists "plans_delete_by_scope" on azul.installment_plans;
create policy "plans_delete_by_scope"
on azul.installment_plans
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.installment_plans.firm_id
      and m.role = 'firm_admin'
  )
  or (
    exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.client_id = azul.installment_plans.client_id
    )
    and origin = 'client'
    and created_by = auth.uid()
    and status = 'draft'
  )
);

-- ----------------------------
-- INSTALLMENT_ITEMS
-- ----------------------------

-- SELECT: quem pode ver o plano pai pode ver as parcelas
drop policy if exists "items_select_by_parent" on azul.installment_items;
create policy "items_select_by_parent"
on azul.installment_items
for select
to authenticated
using (
  exists (
    select 1
    from azul.installment_plans p
    where p.id = azul.installment_items.plan_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = p.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or exists ( -- cliente dono
          select 1 from azul.memberships m2
          where m2.user_id = auth.uid()
            and m2.client_id = p.client_id
        )
      )
  )
);

-- INSERT: equipe da firm OU cliente dono (se plan.origin='client' e status in draft/submitted)
drop policy if exists "items_insert_by_scope" on azul.installment_items;
create policy "items_insert_by_scope"
on azul.installment_items
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.installment_plans p
    where p.id = azul.installment_items.plan_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = p.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          exists ( -- cliente dono
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = p.client_id
          )
          and p.origin = 'client'
          and p.created_by = auth.uid()
          and p.status in ('draft','submitted')
        )
      )
  )
);

-- UPDATE: equipe da firm OU cliente dono (enquanto plan.status in draft/submitted)
drop policy if exists "items_update_by_scope" on azul.installment_items;
create policy "items_update_by_scope"
on azul.installment_items
for update
to authenticated
using (
  exists (
    select 1
    from azul.installment_plans p
    where p.id = azul.installment_items.plan_id
      and (
        exists ( -- equipe
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = p.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or (
          exists ( -- cliente dono
            select 1 from azul.memberships m2
            where m2.user_id = auth.uid()
              and m2.client_id = p.client_id
          )
          and p.origin = 'client'
          and p.created_by = auth.uid()
          and p.status in ('draft','submitted')
        )
      )
  )
)
with check (true);

-- DELETE: firm_admin OU cliente dono (plan.origin='client', status in draft/submitted, e parcela não pode estar 'paid')
drop policy if exists "items_delete_by_scope" on azul.installment_items;
create policy "items_delete_by_scope"
on azul.installment_items
for delete
to authenticated
using (
  exists (
    select 1
    from azul.installment_plans p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role = 'firm_admin'
    where p.id = azul.installment_items.plan_id
  )
  or (
    exists (
      select 1
      from azul.installment_plans p2
      join azul.memberships m2
        on m2.user_id = auth.uid()
       and m2.client_id = p2.client_id
      where p2.id = azul.installment_items.plan_id
        and p2.origin = 'client'
        and p2.created_by = auth.uid()
        and p2.status in ('draft','submitted')
    )
    and azul.installment_items.status <> 'paid'
  )
);

-- ----------------------------
-- INSTALLMENT_EVENTS (logs)
-- ----------------------------

-- SELECT: equipe da firm (todos os eventos) OU cliente do plano
drop policy if exists "installment_events_select_by_scope" on azul.installment_events;
create policy "installment_events_select_by_scope"
on azul.installment_events
for select
to authenticated
using (
  exists (
    select 1
    from azul.installment_plans p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = azul.installment_events.plan_id
  )
  or exists (
    select 1
    from azul.installment_plans p2
    join azul.memberships m2
      on m2.user_id = auth.uid()
     and m2.client_id = p2.client_id
    where p2.id = azul.installment_events.plan_id
  )
);

-- INSERT: qualquer usuário autenticado que tenha acesso de leitura ao plano
drop policy if exists "installment_events_insert_by_readers" on azul.installment_events;
create policy "installment_events_insert_by_readers"
on azul.installment_events
for insert
to authenticated
with check (
  exists (
    select 1
    from azul.installment_plans p
    where p.id = azul.installment_events.plan_id
      and (
        exists (
          select 1 from azul.memberships m
          where m.user_id = auth.uid()
            and m.firm_id = p.firm_id
            and m.role in ('firm_admin','firm_staff')
        )
        or exists (
          select 1 from azul.memberships m2
          where m2.user_id = auth.uid()
            and m2.client_id = p.client_id
        )
      )
  )
);

-- UPDATE/DELETE: bloqueado por padrão
drop policy if exists "installment_events_update_none" on azul.installment_events;
create policy "installment_events_update_none"
on azul.installment_events
for update
to authenticated
using (false)
with check (false);

drop policy if exists "installment_events_delete_none" on azul.installment_events;
create policy "installment_events_delete_none"
on azul.installment_events
for delete
to authenticated
using (false);
