# Azul Contabilidade
## DB Schemas

```pgsql
/db
  /schemas
    01_base.sql
    02_blog.sql
    03_documents.sql
    04_installments.sql
    05_certificates.sql
    06_warnings.sql
    07_integrations.sql
    08_dashboards.sql
```
---

### 01. **Base**

* `profiles` → usuários autenticados (ligados ao Supabase Auth).
* `firms` → escritórios/empresas (multi-tenant).
* `memberships` → vincula `profiles` a `firms` e, opcionalmente, a `clients`, com papéis (`firm_admin`, `firm_staff`, `client_admin`, `client_user`).

### 02. **Blog**

* `blog_posts` → artigos com autor, status, SEO, etc.
* `blog_categories`, `blog_tags`, `blog_post_tags`.
* FKs para firm e autor.
* RLS: autores podem gerenciar seus posts, staff/admin podem gerenciar tudo da firm.

### 03. **Clients**

* `clients` → empresas/entidades atendidas.
* Relacionadas a `firms`.
* Estrutura básica: nome, CNPJ/CPF, contatos.

### 04. **Documents**

* `documents` → arquivos/documentos de clientes.
* `document_types` (referência).
* Metadata: vencimento, status, storage\_url.
* RLS: staff/admin da firm acessam todos, clientes só os seus.

### 05. **Certificates**

* `certificates` → certificados digitais A1/A3 vinculados a clients.
* `certificate_attachments` → arquivos relacionados.
* Status, vencimento, responsavel.
* RLS: staff/admin full; clientes só seus.

### 06. **Warnings**

* `warnings` → recados/avisos para staff/clients.
* Configuração de severidade, status, janela de validade, canais, pinned, requires\_ack.
* `warning_acknowledgements` → ciência de usuários.
* RLS: staff vê tudo; clientes só warnings publicados e válidos.

### 07. **Integrações**

* `integration_connections` → credenciais e config de integrações (Omie, Komunic, etc).
* `integration_tokens`, `integration_webhooks`, `integration_jobs`, `integration_entities_map`.
* `integration_messages` → mensageria (inbound/outbound, canais).
* RLS: staff/admin controlam conexões; clientes veem mensagens próprias.

### 08. **Dashboards**

* `site_sessions`, `site_pageviews`, `site_events`.
* `site_metrics_daily` → agregados diários.
* `blog_post_stats_daily`.
* Views (`vw_blog_top_posts_30d`, `vw_site_kpis_7d`).
* Funções utilitárias (`upsert_site_metric_daily`, etc).

### 09. **Backoffice**

* `site_settings` → configurações do portal (branding, módulos ativos).
* `dashboard_cards` e `dashboard_preferences`.
* `feature_flags` (rollout de features).
* `integration_links` → atalhos amigáveis para integrações.

---

## 🗂 DBML

**Arquivo DBML** para visualizar no [dbdiagram.io](https://dbdiagram.io) ou [drawdb.app](https://drawdb.app):

```dbml
// =========================================================
// Azul Contábil - DBML Schema (01–09)
// =========================================================

Table profiles {
  id uuid [pk]
  full_name text
  email text
  avatar_url text
  created_at timestamptz
  updated_at timestamptz
}

Table firms {
  id uuid [pk]
  name text
  cnpj text
  created_at timestamptz
  updated_at timestamptz
}

Table memberships {
  id uuid [pk]
  user_id uuid [ref: > profiles.id]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  role text
  created_at timestamptz
}

Table clients {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  name text
  cnpj text
  email text
  phone text
  created_at timestamptz
}

Table blog_posts {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  author_id uuid [ref: > profiles.id]
  title text
  slug text
  status text
  published_at timestamptz
  created_at timestamptz
}

Table documents {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  type_id uuid [ref: > document_types.id]
  title text
  storage_url text
  expires_at timestamptz
  created_at timestamptz
}

Table document_types {
  id uuid [pk]
  key text
  label text
}

Table certificates {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  type text
  serial_number text
  status text
  expires_at timestamptz
  created_at timestamptz
}

Table certificate_attachments {
  id uuid [pk]
  certificate_id uuid [ref: > certificates.id]
  file_url text
  created_at timestamptz
}

Table warnings {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  title text
  body text
  severity text
  status text
  start_at timestamptz
  end_at timestamptz
  requires_ack boolean
  pinned boolean
  created_at timestamptz
}

Table warning_acknowledgements {
  warning_id uuid [ref: > warnings.id]
  user_id uuid [ref: > profiles.id]
  ack_at timestamptz
  primary key (warning_id, user_id)
}

Table integration_connections {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  provider text
  kind text
  status text
  env text
  created_at timestamptz
}

Table integration_tokens {
  id uuid [pk]
  connection_id uuid [ref: > integration_connections.id]
  access_token_ref text
  refresh_token_ref text
  expires_at timestamptz
}

Table integration_webhooks {
  id uuid [pk]
  connection_id uuid [ref: > integration_connections.id]
  event text
  target_url text
  is_active boolean
}

Table integration_jobs {
  id uuid [pk]
  connection_id uuid [ref: > integration_connections.id]
  operation text
  resource text
  status text
  created_at timestamptz
}

Table integration_entities_map {
  id uuid [pk]
  connection_id uuid [ref: > integration_connections.id]
  local_type text
  local_id uuid
  external_type text
  external_id text
  last_synced_at timestamptz
}

Table integration_messages {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  client_id uuid [ref: > clients.id]
  connection_id uuid [ref: > integration_connections.id]
  direction text
  channel text
  status text
  content text
  created_at timestamptz
}

Table site_sessions {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  viewer_id uuid [ref: > profiles.id]
  started_at timestamptz
  ended_at timestamptz
}

Table site_pageviews {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  session_id uuid [ref: > site_sessions.id]
  page_path text
  viewed_at timestamptz
}

Table site_events {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  session_id uuid [ref: > site_sessions.id]
  event_name text
  occurred_at timestamptz
}

Table site_metrics_daily {
  firm_id uuid [ref: > firms.id]
  day date
  page_path text
  sessions int
  pageviews int
  users int
  bounces int
  avg_session_seconds numeric
  primary key (firm_id, day, page_path)
}

Table blog_post_stats_daily {
  post_id uuid [ref: > blog_posts.id]
  firm_id uuid [ref: > firms.id]
  day date
  views int
  unique_views int
  reads int
  avg_read_time_seconds numeric
  primary key (post_id, day)
}

Table site_settings {
  firm_id uuid [pk, ref: > firms.id]
  site_name text
  logo_url text
  primary_color text
  enable_blog boolean
  enable_documents boolean
}

Table dashboard_cards {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  key text
  title text
}

Table dashboard_preferences {
  user_id uuid [ref: > profiles.id]
  card_id uuid [ref: > dashboard_cards.id]
  position int
  size text
  primary key (user_id, card_id)
}

Table feature_flags {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  feature_key text
  is_enabled boolean
}

Table integration_links {
  id uuid [pk]
  firm_id uuid [ref: > firms.id]
  connection_id uuid [ref: > integration_connections.id]
  label text
  url text
  visible_to_client boolean
}
```


👉 Quer que eu já prepare também um **README.md** com instruções de aplicação (ordem correta dos scripts, como rodar no Supabase, como testar RLS com `auth.uid()` simulado)?
