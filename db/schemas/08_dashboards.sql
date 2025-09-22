-- =========================================================
-- Schema: Dashboards & Analytics (Site + Blog)
-- Projeto: Azul Contábil
-- Pré-requisitos: 01_base.sql, 02_blog.sql
-- =========================================================

-- =========================================================
-- 1) Enums
-- =========================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'device_enum') then
    create type azul.device_enum as enum ('desktop','mobile','tablet','bot','unknown');
  end if;
end$$;

-- =========================================================
-- 2) Site Analytics (sessions, pageviews, events)
-- =========================================================

-- 2.1) Sessões de site
create table if not exists azul.site_sessions (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,

  viewer_id uuid references azul.profiles(id) on delete set null,

  session_key text unique,
  ip inet,
  user_agent text,
  device azul.device_enum not null default 'unknown',

  country_code text,
  region text,
  city text,

  referrer_host text,
  utm_source  text,
  utm_medium  text,
  utm_campaign text,
  utm_term    text,
  utm_content text,

  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  duration_seconds int,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_site_sessions_firm        on azul.site_sessions(firm_id);
create index if not exists idx_site_sessions_started     on azul.site_sessions(started_at);
create index if not exists idx_site_sessions_viewer      on azul.site_sessions(viewer_id);
create index if not exists idx_site_sessions_referrer    on azul.site_sessions(referrer_host);
create index if not exists idx_site_sessions_utm         on azul.site_sessions(utm_source, utm_medium, utm_campaign);

create trigger trg_site_sessions_updated_at
before update on azul.site_sessions
for each row execute function azul.set_updated_at();

-- 2.2) Pageviews
create table if not exists azul.site_pageviews (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  session_id uuid not null references azul.site_sessions(id) on delete cascade,

  page_path text not null,
  page_title text,
  referrer_url text,

  is_entry boolean not null default false,
  is_exit  boolean not null default false,

  viewed_at timestamptz not null default now(),
  time_on_page_seconds int,
  scroll_depth_percent numeric(5,2),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_pageviews_firm          on azul.site_pageviews(firm_id);
create index if not exists idx_pageviews_session       on azul.site_pageviews(session_id);
create index if not exists idx_pageviews_viewed        on azul.site_pageviews(viewed_at);
create index if not exists idx_pageviews_path          on azul.site_pageviews(page_path);

create trigger trg_site_pageviews_updated_at
before update on azul.site_pageviews
for each row execute function azul.set_updated_at();

-- 2.3) Eventos personalizados
create table if not exists azul.site_events (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  session_id uuid references azul.site_sessions(id) on delete set null,
  pageview_id uuid references azul.site_pageviews(id) on delete set null,
  user_id uuid references azul.profiles(id) on delete set null,

  event_name text not null,
  event_params jsonb not null default '{}'::jsonb,
  page_path text,
  occurred_at timestamptz not null default now(),

  created_at timestamptz not null default now()
);

create index if not exists idx_site_events_firm      on azul.site_events(firm_id);
create index if not exists idx_site_events_name_time on azul.site_events(event_name, occurred_at);
create index if not exists idx_site_events_session   on azul.site_events(session_id);

-- =========================================================
-- 3) Agregados diários (Site + Blog)
-- =========================================================

-- 3.1) Métricas diárias do Site
create table if not exists azul.site_metrics_daily (
  firm_id uuid not null references azul.firms(id) on delete cascade,
  day date not null,
  page_path text,
  sessions int not null default 0,
  pageviews int not null default 0,
  users int not null default 0,
  bounces int not null default 0,
  avg_session_seconds numeric(10,2) not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (firm_id, day, page_path)
);

create index if not exists idx_site_metrics_daily_day on azul.site_metrics_daily(day);

create trigger trg_site_metrics_daily_updated_at
before update on azul.site_metrics_daily
for each row execute function azul.set_updated_at();

-- 3.2) Métricas diárias do Blog por Post
create table if not exists azul.blog_post_stats_daily (
  post_id uuid not null references azul.blog_posts(id) on delete cascade,
  firm_id uuid not null references azul.firms(id) on delete cascade,
  day date not null,

  views int not null default 0,
  unique_views int not null default 0,
  reads int not null default 0,
  avg_read_time_seconds numeric(10,2) not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (post_id, day)
);

create index if not exists idx_blog_post_stats_firm_day on azul.blog_post_stats_daily(firm_id, day);

create trigger trg_blog_post_stats_daily_updated_at
before update on azul.blog_post_stats_daily
for each row execute function azul.set_updated_at();

-- =========================================================
-- 4) Funções utilitárias (ETL/rollups)
-- =========================================================

-- Upsert em site_metrics_daily
create or replace function azul.upsert_site_metric_daily(
  p_firm_id uuid,
  p_day date,
  p_page_path text,
  p_sessions int,
  p_pageviews int,
  p_users int,
  p_bounces int,
  p_avg_session_seconds numeric
) returns void
language plpgsql
as $$
begin
  insert into azul.site_metrics_daily (firm_id, day, page_path, sessions, pageviews, users, bounces, avg_session_seconds)
  values (p_firm_id, p_day, p_page_path, p_sessions, p_pageviews, p_users, p_bounces, p_avg_session_seconds)
  on conflict (firm_id, day, page_path)
  do update set
    sessions = excluded.sessions,
    pageviews = excluded.pageviews,
    users = excluded.users,
    bounces = excluded.bounces,
    avg_session_seconds = excluded.avg_session_seconds,
    updated_at = now();
end;
$$;

-- Upsert em blog_post_stats_daily
create or replace function azul.upsert_blog_post_stats_daily(
  p_post_id uuid,
  p_firm_id uuid,
  p_day date,
  p_views int,
  p_unique_views int,
  p_reads int,
  p_avg_read_time_seconds numeric
) returns void
language plpgsql
as $$
begin
  insert into azul.blog_post_stats_daily (post_id, firm_id, day, views, unique_views, reads, avg_read_time_seconds)
  values (p_post_id, p_firm_id, p_day, p_views, p_unique_views, p_reads, p_avg_read_time_seconds)
  on conflict (post_id, day)
  do update set
    views = excluded.views,
    unique_views = excluded.unique_views,
    reads = excluded.reads,
    avg_read_time_seconds = excluded.avg_read_time_seconds,
    updated_at = now();
end;
$$;

-- ✅ Corrigida: calcula totais diários com casts compatíveis
create or replace function azul.compute_daily_site_totals(p_firm_id uuid, p_day date)
returns void
language sql
as $$
with sess as (
  select
    s.id,
    count(pv.id)::int as pv_count,
    extract(epoch from coalesce(s.ended_at, now()) - s.started_at)::int as dur
  from azul.site_sessions s
  left join azul.site_pageviews pv on pv.session_id = s.id
  where s.firm_id = p_firm_id
    and s.started_at::date = p_day
  group by s.id
),
tot as (
  select
    count(*)::int                              as sessions,
    coalesce(sum(pv_count), 0)::int            as pageviews,
    count(*) filter (where pv_count = 1)::int  as bounces,
    coalesce(avg(dur), 0)::numeric             as avg_session_seconds
  from sess
)
select azul.upsert_site_metric_daily(
  p_firm_id,
  p_day,
  NULL::text,                                  -- evitar tipo unknown
  (select sessions from tot)::int,
  (select pageviews from tot)::int,
  (select sessions from tot)::int,             -- users ~ sessions (aprox.)
  (select bounces from tot)::int,
  (select avg_session_seconds from tot)::numeric
);
$$;

-- =========================================================
-- 5) Views úteis (Dashboards)
-- =========================================================

create or replace view azul.vw_blog_top_posts_30d as
select
  p.id as post_id,
  p.firm_id,
  p.title,
  p.slug,
  sum(d.views) as views_30d,
  sum(d.unique_views) as unique_views_30d,
  sum(d.reads) as reads_30d,
  round(avg(nullif(d.avg_read_time_seconds,0))::numeric, 2) as avg_read_time_seconds
from azul.blog_post_stats_daily d
join azul.blog_posts p on p.id = d.post_id
where d.day >= (current_date - interval '30 days')
group by p.id, p.firm_id, p.title, p.slug;

create or replace view azul.vw_site_kpis_7d as
select
  firm_id,
  sum(sessions) as sessions_7d,
  sum(pageviews) as pageviews_7d,
  sum(users) as users_7d,
  sum(bounces) as bounces_7d,
  round(avg(nullif(avg_session_seconds,0))::numeric, 2) as avg_session_seconds_7d
from azul.site_metrics_daily
where day >= (current_date - interval '7 days')
group by firm_id;

-- =========================================================
-- 6) RLS
-- =========================================================

alter table azul.site_sessions         enable row level security;
alter table azul.site_pageviews        enable row level security;
alter table azul.site_events           enable row level security;
alter table azul.site_metrics_daily    enable row level security;
alter table azul.blog_post_stats_daily enable row level security;

-- SITE_SESSIONS
drop policy if exists "sessions_select_staff" on azul.site_sessions;
create policy "sessions_select_staff"
on azul.site_sessions for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_sessions.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "sessions_insert_staff" on azul.site_sessions;
create policy "sessions_insert_staff"
on azul.site_sessions for insert to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_sessions.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "sessions_update_staff" on azul.site_sessions;
create policy "sessions_update_staff"
on azul.site_sessions for update to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_sessions.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_sessions.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "sessions_delete_admin" on azul.site_sessions;
create policy "sessions_delete_admin"
on azul.site_sessions for delete to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_sessions.firm_id
      and m.role = 'firm_admin'
  )
);

-- SITE_PAGEVIEWS
drop policy if exists "pageviews_select_staff" on azul.site_pageviews;
create policy "pageviews_select_staff"
on azul.site_pageviews for select to authenticated
using (
  exists (
    select 1
    from azul.site_sessions s
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = s.firm_id
     and m.role in ('firm_admin','firm_staff')
    where s.id = site_pageviews.session_id
  )
);

drop policy if exists "pageviews_insert_staff" on azul.site_pageviews;
create policy "pageviews_insert_staff"
on azul.site_pageviews for insert to authenticated
with check (
  exists (
    select 1
    from azul.site_sessions s
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = s.firm_id
     and m.role in ('firm_admin','firm_staff')
    where s.id = site_pageviews.session_id
  )
);

drop policy if exists "pageviews_update_staff" on azul.site_pageviews;
create policy "pageviews_update_staff"
on azul.site_pageviews for update to authenticated
using (
  exists (
    select 1
    from azul.site_sessions s
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = s.firm_id
     and m.role in ('firm_admin','firm_staff')
    where s.id = site_pageviews.session_id
  )
)
with check (
  exists (
    select 1
    from azul.site_sessions s
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = s.firm_id
     and m.role in ('firm_admin','firm_staff')
    where s.id = site_pageviews.session_id
  )
);

drop policy if exists "pageviews_delete_admin" on azul.site_pageviews;
create policy "pageviews_delete_admin"
on azul.site_pageviews for delete to authenticated
using (
  exists (
    select 1
    from azul.site_sessions s
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = s.firm_id
     and m.role = 'firm_admin'
    where s.id = site_pageviews.session_id
  )
);

-- SITE_EVENTS
drop policy if exists "events_select_staff" on azul.site_events;
create policy "events_select_staff"
on azul.site_events for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_events.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "events_insert_staff" on azul.site_events;
create policy "events_insert_staff"
on azul.site_events for insert to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_events.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "events_update_staff" on azul.site_events;
create policy "events_update_staff"
on azul.site_events for update to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_events.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_events.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "events_delete_admin" on azul.site_events;
create policy "events_delete_admin"
on azul.site_events for delete to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_events.firm_id
      and m.role = 'firm_admin'
  )
);

-- SITE_METRICS_DAILY
drop policy if exists "site_metrics_select_staff" on azul.site_metrics_daily;
create policy "site_metrics_select_staff"
on azul.site_metrics_daily for select to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_metrics_daily.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "site_metrics_write_staff" on azul.site_metrics_daily;
create policy "site_metrics_write_staff"
on azul.site_metrics_daily for insert to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_metrics_daily.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "site_metrics_update_staff" on azul.site_metrics_daily;
create policy "site_metrics_update_staff"
on azul.site_metrics_daily for update to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_metrics_daily.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_metrics_daily.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

drop policy if exists "site_metrics_delete_admin" on azul.site_metrics_daily;
create policy "site_metrics_delete_admin"
on azul.site_metrics_daily for delete to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = site_metrics_daily.firm_id
      and m.role = 'firm_admin'
  )
);

-- BLOG_POST_STATS_DAILY
drop policy if exists "blog_stats_select_staff_or_author" on azul.blog_post_stats_daily;
create policy "blog_stats_select_staff_or_author"
on azul.blog_post_stats_daily for select to authenticated
using (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_stats_daily.post_id
  )
  or exists (
    select 1 from azul.blog_posts p2
    where p2.id = blog_post_stats_daily.post_id
      and p2.author_id = auth.uid()
  )
);

drop policy if exists "blog_stats_write_staff" on azul.blog_post_stats_daily;
create policy "blog_stats_write_staff"
on azul.blog_post_stats_daily for insert to authenticated
with check (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_stats_daily.post_id
  )
);

drop policy if exists "blog_stats_update_staff" on azul.blog_post_stats_daily;
create policy "blog_stats_update_staff"
on azul.blog_post_stats_daily for update to authenticated
using (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_stats_daily.post_id
  )
)
with check (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_stats_daily.post_id
  )
);

drop policy if exists "blog_stats_delete_admin" on azul.blog_post_stats_daily;
create policy "blog_stats_delete_admin"
on azul.blog_post_stats_daily for delete to authenticated
using (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role = 'firm_admin'
    where p.id = blog_post_stats_daily.post_id
  )
);
