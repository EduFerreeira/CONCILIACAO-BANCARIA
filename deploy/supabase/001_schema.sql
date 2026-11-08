-- Aplicar em projeto Supabase dedicado. Não contém senhas ou chaves.
begin;
create table if not exists public.pf_users (
 id uuid primary key references auth.users(id), name text not null check(length(name) between 1 and 160), email text unique not null,
 role text not null check(role in ('admin','reviewer','responsible')), active boolean not null default true,
 must_change boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.pf_memberships(user_id uuid references public.pf_users(id),company text check(company in ('ponto','agricola','mutuo')),primary key(user_id,company));
create table if not exists public.pf_sessions(session_id uuid primary key,user_id uuid not null references public.pf_users(id),expires_at timestamptz not null default now()+interval '8 hours');
create table if not exists public.pf_login_attempts(email text not null,ip text not null,at timestamptz not null default now());
create index if not exists pf_attempts_time on public.pf_login_attempts(at);
create table if not exists public.pf_workspaces(company text primary key check(company in ('ponto','agricola','mutuo')),version integer not null default 0,document jsonb not null,updated_by uuid references public.pf_users(id),updated_at timestamptz not null default now(),sync_version integer not null default -1,sync_digest text);
create table if not exists public.pf_tasks (
 id uuid primary key default gen_random_uuid(),company text not null references public.pf_workspaces(company),financial_key text not null,
 account text not null,account_name text not null,date date not null,description text not null,cents bigint not null,
 side text not null check(side in ('bank','system')),missing_in text not null check(missing_in in ('bank','system')),reference text not null,
 status text not null default 'pending' check(status in ('pending','in_progress','waiting_document','awaiting_review','resolved')),
 assignee uuid references public.pf_users(id),due_date date,note text not null default '',financial_present boolean not null default true,
 reconciliation_version integer not null,submitted_by uuid references public.pf_users(id),submitted_version integer,
 version integer not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(company,financial_key)
);
create index if not exists pf_tasks_owner on public.pf_tasks(assignee,company,status);
create table if not exists public.pf_events(id uuid primary key default gen_random_uuid(),company text,task_id uuid references public.pf_tasks(id),actor_id uuid not null,actor_name text not null,action text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create index if not exists pf_events_task on public.pf_events(task_id,created_at);
create table if not exists public.pf_attachments(id uuid primary key default gen_random_uuid(),task_id uuid not null references public.pf_tasks(id),filename text not null,media_type text not null,size integer not null check(size between 1 and 8388608),storage_name text unique not null,uploaded_by uuid not null references public.pf_users(id),created_at timestamptz not null default now());
create table if not exists public.pf_notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.pf_users(id),task_id uuid not null references public.pf_tasks(id),message text not null,created_at timestamptz not null default now(),read_at timestamptz);
insert into public.pf_workspaces(company,document) select company,jsonb_build_object('version',1,'workspaceId',company,'accounts','[]'::jsonb,'transactions','[]'::jsonb,'applications','[]'::jsonb,'importedBalances','[]'::jsonb,'pendingTracking','{}'::jsonb,'statementAnnotations','[]'::jsonb,'statementNotices','[]'::jsonb) || case when company='mutuo' then '{"mutuo":{"version":1,"rule":"opposite","records":[],"pairs":[],"imports":[]}}'::jsonb else '{}'::jsonb end from unnest(array['ponto','agricola','mutuo']) company on conflict do nothing;

create or replace function public.pf_fail(code integer,message text) returns void language plpgsql as $$begin raise exception 'PF%|%',code,message;end$$;
create or replace function public.pf_session_valid() returns boolean language sql stable security definer set search_path=public,pg_temp as $$select exists(select 1 from public.pf_sessions s join public.pf_users u on u.id=s.user_id where s.user_id=auth.uid() and s.session_id::text=auth.jwt()->>'session_id' and s.expires_at>now() and u.active)$$;
create or replace function public.pf_actor(require_ready boolean default true) returns public.pf_users language plpgsql stable security definer set search_path=public,pg_temp as $$declare actor public.pf_users;begin select * into actor from public.pf_users where id=auth.uid() and active;if actor.id is null or not public.pf_session_valid() then perform public.pf_fail(401,'Entre com seu login.');end if;if require_ready and actor.must_change then perform public.pf_fail(403,'Troque sua senha temporária antes de continuar.');end if;return actor;end$$;
create or replace function public.pf_can_company(company_id text) returns boolean language sql stable security definer set search_path=public,pg_temp as $$select public.pf_session_valid() and exists(select 1 from public.pf_memberships m join public.pf_users u on u.id=m.user_id where m.user_id=auth.uid() and m.company=company_id and not u.must_change and u.active)$$;
create or replace function public.pf_can_task(task_id uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$select exists(select 1 from public.pf_tasks t join public.pf_users u on u.id=auth.uid() where t.id=task_id and public.pf_can_company(t.company) and (u.role in ('admin','reviewer') or t.assignee=u.id))$$;
create or replace function public.pf_user_json(user_id uuid) returns jsonb language sql stable security definer set search_path=public,pg_temp as $$select jsonb_build_object('id',u.id,'name',u.name,'email',u.email,'role',u.role,'active',u.active,'must_change',u.must_change,'companies',coalesce((select jsonb_agg(company order by company) from public.pf_memberships where user_id=u.id),'[]'::jsonb)) from public.pf_users u where u.id=user_id$$;
create or replace function public.pf_task_json(task_id uuid) returns jsonb language sql stable security definer set search_path=public,pg_temp as $$select (to_jsonb(t)-'financial_key')||jsonb_build_object('assignee_name',coalesce(u.name,'')) from public.pf_tasks t left join public.pf_users u on u.id=t.assignee where t.id=task_id$$;
create or replace function public.pf_event(actor_id uuid,action_name text,body jsonb default '{}',company_id text default null,task_id uuid default null) returns void language sql security definer set search_path=public,pg_temp as $$insert into public.pf_events(actor_id,actor_name,action,details,company,task_id) select id,name,action_name,body,company_id,task_id from public.pf_users where id=actor_id$$;
create or replace function public.pf_notify(user_id uuid,task_id uuid,message text) returns void language sql security definer set search_path=public,pg_temp as $$insert into public.pf_notifications(user_id,task_id,message) select user_id,task_id,message where user_id is not null$$;

-- Tabelas privadas: escrita somente por RPC validada. Helpers internos não são APIs.
alter table public.pf_users enable row level security;
alter table public.pf_memberships enable row level security;
alter table public.pf_sessions enable row level security;
alter table public.pf_login_attempts enable row level security;
alter table public.pf_workspaces enable row level security;
alter table public.pf_tasks enable row level security;
alter table public.pf_events enable row level security;
alter table public.pf_attachments enable row level security;
alter table public.pf_notifications enable row level security;
revoke all on public.pf_users,public.pf_memberships,public.pf_sessions,public.pf_login_attempts,public.pf_workspaces,public.pf_tasks,public.pf_events,public.pf_attachments,public.pf_notifications from anon,authenticated;
-- Não conceder execução de helpers que retornam dados a chamadores externos.
revoke all on function public.pf_actor(boolean),public.pf_user_json(uuid),public.pf_task_json(uuid),public.pf_event(uuid,text,jsonb,text,uuid),public.pf_notify(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.pf_session_valid(),public.pf_can_company(text),public.pf_can_task(uuid),public.pf_fail(integer,text) from public,anon;
grant execute on function public.pf_session_valid(),public.pf_can_company(text),public.pf_can_task(uuid) to authenticated;
commit;
