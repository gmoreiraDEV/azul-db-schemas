-- =========================================================
-- Schema: Backoffice (Configurações, Dashboards, Feature Flags, Links)
-- Projeto: Azul Contábil
-- Pré-requisitos: 01_base.sql, 07_integracoes.sql
-- =========================================================

-- =========================================================
-- 1) Configurações do Site / Portal
-- =========================================================
create table if not exists azul.site_settings (
  firm_id uuid primary key references azul.firms(id) on delete cascade,

  site_name text not null default 'Portal Azul',
  logo_url text,
  primary_color text,
  secondary_color text,
  accent_color text,

  domain text,                -- domínio customizado
  enable_blog boolean not null default true,
  enable_documents boolean not null default true,
  enable_certificates boolean not null default true,
  enable_warnings boolean not null default true,
  enable_integrations boolean not null default true,

  seo_meta jsonb not null default '{}'::jsonb,  -- título, descrição, keywords padrão

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_site_settings_updated_at
before update on azul.site_settings
for each row execute function azul.set_updated_at();

-- =========================================================
-- 2) Dashboard Cards (definição dos tipos de cards)
-- =========================================================
create table if not exists azul.dashboard_cards (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,

  key text not null,             -- identificador único do card (ex.: 'sessions_7d')
  title text not null,
  description text,
  icon text,
  query_ref text,                -- ref. à view/função SQL usada
  default_position int,          -- ordem inicial sugerida
  default_size text,             -- ex.: 'small','medium','large'

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (firm_id, key)
);

create trigger trg_dashboard_cards_updated_at
before update on azul.dashboard_cards
for each row execute function azul.set_updated_at();

-- =========================================================
-- 3) Dashboard Preferences (por usuário)
-- =========================================================
create table if not exists azul.dashboard_preferences (
  user_id uuid not null references azul.profiles(id) on delete cascade,
  card_id uuid not null references azul.dashboard_cards(id) on delete cascade,

  position int,
  size text,
  filters jsonb not null default '{}'::jsonb,
  is_hidden boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (user_id, card_id)
);

create trigger trg_dashboard_preferences_updated_at
before update on azul.dashboard_preferences
for each row execute function azul.set_updated_at();

-- =========================================================
-- 4) Feature Flags (ativar/desativar por firm)
-- =========================================================
create table if not exists azul.feature_flags (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,

  feature_key text not null,     -- ex.: 'new_dashboard', 'ai_assistant'
  is_enabled boolean not null default false,
  rollout jsonb not null default '{}'::jsonb,  -- ex.: % rollout, público-alvo

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (firm_id, feature_key)
);

create trigger trg_feature_flags_updated_at
before update on azul.feature_flags
for each row execute function azul.set_updated_at();

-- =========================================================
-- 5) Integration Links (atalhos amigáveis no portal/backoffice)
-- =========================================================
create table if not exists azul.integration_links (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  connection_id uuid not null references azul.integration_connections(id) on delete cascade,

  label text not null,         -- "Abrir Omie", "Acessar Komunic"
  url text not null,
  visible_to_client boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_integration_links_firm on azul.integration_links(firm_id);

create trigger trg_integration_links_updated_at
before update on azul.integration_links
for each row execute function azul.set_updated_at();

-- =========================================================
-- 6) RLS
-- =========================================================

alter table azul.site_settings           enable row level security;
alter table azul.dashboard_cards         enable row level security;
alter table azul.dashboard_preferences   enable row level security;
alter table azul.feature_flags           enable row level security;
alter table azul.integration_links       enable row level security;

-- ----------------------------
-- SITE_SETTINGS
-- ----------------------------
drop policy if exists "settings_select_staff_or_client" on azul.site_settings;
create policy "settings_select_staff_or_client"
on azul.site_settings
for select to authenticated
using (
  -- staff da firm vê sempre
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_settings.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or
  -- cliente pode ver configurações se enable_integrations/blog/etc. forem públicas
  exists (
    select 1 from azul.memberships m2
    where m2.user_id = auth.uid()
      and m2.firm_id = site_settings.firm_id
  )
);

drop policy if exists "settings_write_staff" on azul.site_settings;
create policy "settings_write_staff"
on azul.site_settings
for all to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_settings.firm_id
      and m.role = 'firm_admin'
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_settings.firm_id
      and m.role = 'firm_admin'
  )
);

-- ----------------------------
-- DASHBOARD_CARDS
-- ----------------------------
drop policy if exists "cards_select_staff" on azul.dashboard_cards;
create policy "cards_select_staff"
on azul.dashboard_cards
for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = dashboard_cards.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "cards_write_admin" on azul.dashboard_cards;
create policy "cards_write_admin"
on azul.dashboard_cards
for all to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = dashboard_cards.firm_id
      and m.role = 'firm_admin'
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = dashboard_cards.firm_id
      and m.role = 'firm_admin'
  )
);

-- ----------------------------
-- DASHBOARD_PREFERENCES
-- ----------------------------
drop policy if exists "prefs_select_self" on azul.dashboard_preferences;
create policy "prefs_select_self"
on azul.dashboard_preferences
for select to authenticated
using (user_id = auth.uid());

drop policy if exists "prefs_write_self" on azul.dashboard_preferences;
create policy "prefs_write_self"
on azul.dashboard_preferences
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- ----------------------------
-- FEATURE_FLAGS
-- ----------------------------
drop policy if exists "flags_select_staff" on azul.feature_flags;
create policy "flags_select_staff"
on azul.feature_flags
for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = feature_flags.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "flags_write_admin" on azul.feature_flags;
create policy "flags_write_admin"
on azul.feature_flags
for all to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = feature_flags.firm_id
      and m.role = 'firm_admin'
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = feature_flags.firm_id
      and m.role = 'firm_admin'
  )
);

-- ----------------------------
-- INTEGRATION_LINKS
-- ----------------------------
drop policy if exists "links_select_scope" on azul.integration_links;
create policy "links_select_scope"
on azul.integration_links
for select to authenticated
using (
  -- staff sempre vê
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_links.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or (
    -- cliente só vê se visible_to_client = true
    integration_links.visible_to_client
    and exists (
      select 1 from azul.memberships m2
      where m2.user_id = auth.uid()
        and m2.firm_id = integration_links.firm_id
    )
  )
);

drop policy if exists "links_write_admin" on azul.integration_links;
create policy "links_write_admin"
on azul.integration_links
for all to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_links.firm_id
      and m.role = 'firm_admin'
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = integration_links.firm_id
      and m.role = 'firm_admin'
  )
);
