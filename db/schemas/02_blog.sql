-- =========================================================
-- Schema: Blog (posts, categorias, tags, relacionamentos)
-- Projeto: Azul Contábil
-- Pré-requisito: 01_base.sql (schema azul, memberships, profiles, etc.)
-- =========================================================

-- 1) Enums
do $$
begin
  if not exists (select 1 from pg_type where typname = 'post_status_enum') then
    create type azul.post_status_enum as enum (
      'draft',
      'scheduled',
      'published',
      'archived'
    );
  end if;
end$$;

-- 2) Tabelas principais

-- 2.1) Categorias
create table if not exists azul.blog_categories (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  name text not null,
  slug text not null,
  description text,
  is_public boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint blog_categories_slug_chk check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint blog_categories_unique_slug_per_firm unique (firm_id, slug)
);

create index if not exists idx_blog_categories_firm on azul.blog_categories(firm_id);

create trigger trg_blog_categories_updated_at
before update on azul.blog_categories
for each row execute function azul.set_updated_at();

-- 2.2) Tags
create table if not exists azul.blog_tags (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  name text not null,
  slug text not null,
  description text,
  is_public boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint blog_tags_slug_chk check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint blog_tags_unique_slug_per_firm unique (firm_id, slug)
);

create index if not exists idx_blog_tags_firm on azul.blog_tags(firm_id);

create trigger trg_blog_tags_updated_at
before update on azul.blog_tags
for each row execute function azul.set_updated_at();

-- 2.3) Posts
create table if not exists azul.blog_posts (
  id uuid primary key default gen_random_uuid(),
  firm_id uuid not null references azul.firms(id) on delete cascade,
  author_id uuid not null references azul.profiles(id) on delete restrict,
  title text not null,
  slug text not null,
  excerpt text,
  content text,                      -- markdown/HTML livre
  cover_image_url text,
  seo_title text,
  seo_description text,
  canonical_url text,
  read_time_minutes int,
  status azul.post_status_enum not null default 'draft',
  published_at timestamptz,
  is_featured boolean not null default false,

  -- Repost de artigo (atribuição de fonte)
  is_repost boolean not null default false,
  repost_source_name text,
  repost_source_url text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint blog_posts_slug_chk check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  constraint blog_posts_unique_slug_per_firm unique (firm_id, slug),
  constraint blog_posts_repost_chk check (
    (is_repost = false)
    or (is_repost = true and repost_source_url is not null)
  ),
  constraint blog_posts_published_chk check (
    (status <> 'published') or (published_at is not null)
  )
);

create index if not exists idx_blog_posts_firm on azul.blog_posts(firm_id);
create index if not exists idx_blog_posts_status_pub on azul.blog_posts(status, published_at);
create index if not exists idx_blog_posts_author on azul.blog_posts(author_id);

create trigger trg_blog_posts_updated_at
before update on azul.blog_posts
for each row execute function azul.set_updated_at();

-- 3) Relacionamentos N:N

-- 3.1) Post <-> Tags
create table if not exists azul.blog_post_tags (
  post_id uuid not null references azul.blog_posts(id) on delete cascade,
  tag_id  uuid not null references azul.blog_tags(id)  on delete cascade,
  primary key (post_id, tag_id)
);

-- 3.2) Post <-> Categorias (permite múltiplas)
create table if not exists azul.blog_post_categories (
  post_id     uuid not null references azul.blog_posts(id)     on delete cascade,
  category_id uuid not null references azul.blog_categories(id) on delete cascade,
  primary key (post_id, category_id)
);

-- =========================================================
-- RLS
-- =========================================================

-- Ativar RLS
alter table azul.blog_categories    enable row level security;
alter table azul.blog_tags          enable row level security;
alter table azul.blog_posts         enable row level security;
alter table azul.blog_post_tags     enable row level security;
alter table azul.blog_post_categories enable row level security;

-- ---------------------------------------------------------
-- BLOG_POSTS
-- Leitura pública: qualquer um (anon/authenticated) pode ler posts publicados
drop policy if exists "blog_posts_public_read_published" on azul.blog_posts;
create policy "blog_posts_public_read_published"
on azul.blog_posts
for select
to anon, authenticated
using (
  status = 'published'
  and published_at is not null
  and published_at <= now()
);

-- Leitura interna: colaboradores da firm podem ler qualquer post da sua firm (inclui drafts)
drop policy if exists "blog_posts_firm_read_all" on azul.blog_posts;
create policy "blog_posts_firm_read_all"
on azul.blog_posts
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_posts.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
  or author_id = auth.uid()
);

-- INSERT: somente firm_admin/firm_staff da firm
drop policy if exists "blog_posts_insert_firm_staff" on azul.blog_posts;
create policy "blog_posts_insert_firm_staff"
on azul.blog_posts
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_posts.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- UPDATE: autor do post OU firm_admin/firm_staff da firm
drop policy if exists "blog_posts_update_author_or_staff" on azul.blog_posts;
create policy "blog_posts_update_author_or_staff"
on azul.blog_posts
for update
to authenticated
using (
  author_id = auth.uid()
  or exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_posts.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  -- mantém o mesmo escopo de firm
  author_id = auth.uid()
  or exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_posts.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- DELETE: apenas firm_admin da firm
drop policy if exists "blog_posts_delete_admin" on azul.blog_posts;
create policy "blog_posts_delete_admin"
on azul.blog_posts
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_posts.firm_id
      and m.role = 'firm_admin'
  )
);

-- ---------------------------------------------------------
-- BLOG_CATEGORIES
-- Leitura pública quando is_public = true
drop policy if exists "blog_categories_public_read" on azul.blog_categories;
create policy "blog_categories_public_read"
on azul.blog_categories
for select
to anon, authenticated
using (is_public = true);

-- Leitura interna: equipe da firm pode ver todas as categorias da firm
drop policy if exists "blog_categories_firm_read_all" on azul.blog_categories;
create policy "blog_categories_firm_read_all"
on azul.blog_categories
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_categories.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- INSERT: firm_admin/firm_staff
drop policy if exists "blog_categories_insert_staff" on azul.blog_categories;
create policy "blog_categories_insert_staff"
on azul.blog_categories
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_categories.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- UPDATE: firm_admin/firm_staff
drop policy if exists "blog_categories_update_staff" on azul.blog_categories;
create policy "blog_categories_update_staff"
on azul.blog_categories
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_categories.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_categories.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- DELETE: apenas firm_admin
drop policy if exists "blog_categories_delete_admin" on azul.blog_categories;
create policy "blog_categories_delete_admin"
on azul.blog_categories
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_categories.firm_id
      and m.role = 'firm_admin'
  )
);

-- ---------------------------------------------------------
-- BLOG_TAGS
-- Leitura pública quando is_public = true
drop policy if exists "blog_tags_public_read" on azul.blog_tags;
create policy "blog_tags_public_read"
on azul.blog_tags
for select
to anon, authenticated
using (is_public = true);

-- Leitura interna: equipe da firm
drop policy if exists "blog_tags_firm_read_all" on azul.blog_tags;
create policy "blog_tags_firm_read_all"
on azul.blog_tags
for select
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_tags.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- INSERT
drop policy if exists "blog_tags_insert_staff" on azul.blog_tags;
create policy "blog_tags_insert_staff"
on azul.blog_tags
for insert
to authenticated
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_tags.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- UPDATE
drop policy if exists "blog_tags_update_staff" on azul.blog_tags;
create policy "blog_tags_update_staff"
on azul.blog_tags
for update
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_tags.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
)
with check (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_tags.firm_id
      and m.role in ('firm_admin','firm_staff')
  )
);

-- DELETE
drop policy if exists "blog_tags_delete_admin" on azul.blog_tags;
create policy "blog_tags_delete_admin"
on azul.blog_tags
for delete
to authenticated
using (
  exists (
    select 1 from azul.memberships m
    where m.user_id = auth.uid()
      and m.firm_id = azul.blog_tags.firm_id
      and m.role = 'firm_admin'
  )
);

-- ---------------------------------------------------------
-- RELACIONAMENTOS (post_tags e post_categories)
-- SELECT público quando o post está publicado
drop policy if exists "blog_post_tags_public_read" on azul.blog_post_tags;
create policy "blog_post_tags_public_read"
on azul.blog_post_tags
for select
to anon, authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    where p.id = blog_post_tags.post_id
      and p.status = 'published'
      and p.published_at is not null
      and p.published_at <= now()
  )
);

drop policy if exists "blog_post_categories_public_read" on azul.blog_post_categories;
create policy "blog_post_categories_public_read"
on azul.blog_post_categories
for select
to anon, authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    where p.id = blog_post_categories.post_id
      and p.status = 'published'
      and p.published_at is not null
      and p.published_at <= now()
  )
);

-- SELECT interno: equipe da firm pode ver todos os vínculos da própria firm
drop policy if exists "blog_post_tags_firm_read_all" on azul.blog_post_tags;
create policy "blog_post_tags_firm_read_all"
on azul.blog_post_tags
for select
to authenticated
using (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_tags.post_id
  )
);

drop policy if exists "blog_post_categories_firm_read_all" on azul.blog_post_categories;
create policy "blog_post_categories_firm_read_all"
on azul.blog_post_categories
for select
to authenticated
using (
  exists (
    select 1
    from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_categories.post_id
  )
);

-- INSERT/UPDATE/DELETE: somente equipe (staff/admin) da firm do post
drop policy if exists "blog_post_tags_write_staff" on azul.blog_post_tags;
create policy "blog_post_tags_write_staff"
on azul.blog_post_tags
for insert
to authenticated
with check (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_tags.post_id
  )
);

drop policy if exists "blog_post_tags_update_staff" on azul.blog_post_tags;
create policy "blog_post_tags_update_staff"
on azul.blog_post_tags
for update
to authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_tags.post_id
  )
)
with check (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_tags.post_id
  )
);

drop policy if exists "blog_post_tags_delete_staff" on azul.blog_post_tags;
create policy "blog_post_tags_delete_staff"
on azul.blog_post_tags
for delete
to authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_tags.post_id
  )
);

drop policy if exists "blog_post_categories_write_staff" on azul.blog_post_categories;
create policy "blog_post_categories_write_staff"
on azul.blog_post_categories
for insert
to authenticated
with check (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_categories.post_id
  )
);

drop policy if exists "blog_post_categories_update_staff" on azul.blog_post_categories;
create policy "blog_post_categories_update_staff"
on azul.blog_post_categories
for update
to authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_categories.post_id
  )
)
with check (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_categories.post_id
  )
);

drop policy if exists "blog_post_categories_delete_staff" on azul.blog_post_categories;
create policy "blog_post_categories_delete_staff"
on azul.blog_post_categories
for delete
to authenticated
using (
  exists (
    select 1 from azul.blog_posts p
    join azul.memberships m
      on m.user_id = auth.uid()
     and m.firm_id = p.firm_id
     and m.role in ('firm_admin','firm_staff')
    where p.id = blog_post_categories.post_id
  )
);
