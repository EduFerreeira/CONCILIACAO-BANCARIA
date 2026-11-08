begin;
-- Exclusivo da API Cloudflare: service_role nunca deve ir para navegador/HTML.
create or replace function public.pf_service(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_column
declare actor public.pf_users;target public.pf_users;target_id uuid;sid uuid;action_name text;company_id text;email_value text;ip_value text;role_value text;
begin
 if coalesce(auth.role(),'')<>'service_role' then perform public.pf_fail(403,'Operação reservada ao servidor.');end if;
 if p_action='login_attempt' then
  email_value:=lower(p_data->>'email');ip_value:=p_data->>'ip';delete from public.pf_login_attempts where at<now()-interval '15 minutes';
  if (select count(*) from public.pf_login_attempts where email=email_value and ip=ip_value)>=10 or (select count(*) from public.pf_login_attempts where ip=ip_value)>=100 then perform public.pf_fail(429,'Muitas tentativas. Aguarde 15 minutos.');end if;
  insert into public.pf_login_attempts(email,ip) values(email_value,ip_value);return '{"ok":true}';
 end if;
 if p_action='session_register' then
  target_id:=(p_data->>'user_id')::uuid;sid:=(p_data->>'session_id')::uuid;
  select * into target from public.pf_users where id=target_id and active;
  if target.id is null then perform public.pf_fail(403,'Usuário sem acesso ao sistema.');end if;
  delete from public.pf_sessions where expires_at<now();
  insert into public.pf_sessions(session_id,user_id) values(sid,target_id) on conflict(session_id) do nothing;
  delete from public.pf_login_attempts where email=lower(p_data->>'email') and ip=p_data->>'ip';
  perform public.pf_event(target.id,'login','{}');return public.pf_user_json(target.id);
 end if;
 if p_action='password_changed' then
  target_id:=(p_data->>'user_id')::uuid;sid:=(p_data->>'session_id')::uuid;
  update public.pf_users set must_change=false where id=target_id and active;
  if not found then perform public.pf_fail(403,'Acesso indisponível.');end if;
  delete from public.pf_sessions where user_id=target_id;
  insert into public.pf_sessions(session_id,user_id) values(sid,target_id);
  perform public.pf_event(target_id,'password_changed','{}');return '{"ok":true}';
 end if;
 if p_action='user_update' then perform pg_advisory_xact_lock(191832414);end if;
 select * into actor from public.pf_users where id=(p_data->>'actor_id')::uuid and active and role='admin' and not must_change;
 if actor.id is null then perform public.pf_fail(403,'Administrador obrigatório.');end if;
 target_id:=(p_data->>'user_id')::uuid;
 if p_action='user_create' then
  role_value:=p_data->>'role';
  if role_value not in ('admin','reviewer','responsible') or length(trim(coalesce(p_data->>'name',''))) not between 1 and 160 or jsonb_typeof(p_data->'companies') is distinct from 'array' or jsonb_array_length(p_data->'companies')=0 then perform public.pf_fail(422,'Informe nome, perfil e empresas.');end if;
  for company_id in select jsonb_array_elements_text(p_data->'companies') loop
   if not exists(select 1 from public.pf_memberships where user_id=actor.id and company=company_id) then perform public.pf_fail(403,'Empresa fora do seu acesso.');end if;
  end loop;
  insert into public.pf_users(id,name,email,role) values(target_id,trim(p_data->>'name'),lower(p_data->>'email'),role_value);
  insert into public.pf_memberships select target_id,value from jsonb_array_elements_text(p_data->'companies') group by value;
  perform public.pf_event(actor.id,'user_created',jsonb_build_object('user_id',target_id,'name',p_data->>'name','role',role_value,'companies',p_data->'companies'));return jsonb_build_object('id',target_id);
 end if;
 if p_action='user_update' then
  select * into target from public.pf_users where id=target_id for update;
  if target.id is null then perform public.pf_fail(404,'Usuário não encontrado.');end if;
  if exists(select 1 from public.pf_memberships m where m.user_id=target_id and not exists(select 1 from public.pf_memberships mine where mine.user_id=actor.id and mine.company=m.company)) then perform public.pf_fail(403,'Usuário fora das suas empresas.');end if;
  action_name:=p_data->>'action';
  if target_id=actor.id and action_name<>'activate' then perform public.pf_fail(422,'Use outro administrador para alterar seu próprio acesso.');end if;
  if action_name='reset_password' then update public.pf_users set must_change=true where id=target_id;
  elsif action_name in ('activate','deactivate') then update public.pf_users set active=(action_name='activate') where id=target_id;
  elsif action_name='access' then
   role_value:=p_data->>'role';
   if coalesce(role_value,'') not in ('admin','reviewer','responsible') or jsonb_typeof(p_data->'companies') is distinct from 'array' or jsonb_array_length(p_data->'companies')=0 or length(trim(coalesce(p_data->>'reason',''))) not between 1 and 2000 then perform public.pf_fail(422,'Informe perfil, empresas e motivo.');end if;
   for company_id in select jsonb_array_elements_text(p_data->'companies') loop if not exists(select 1 from public.pf_memberships where user_id=actor.id and company=company_id) then perform public.pf_fail(403,'Empresa fora do seu acesso.');end if;end loop;
   update public.pf_users set role=role_value where id=target_id;
   delete from public.pf_memberships where user_id=target_id;
   insert into public.pf_memberships select target_id,value from jsonb_array_elements_text(p_data->'companies') group by value;
  else perform public.pf_fail(422,'Ação inválida.');end if;
  delete from public.pf_sessions where user_id=target_id;
  perform public.pf_event(actor.id,'user_'||action_name,jsonb_build_object('user_id',target_id,'reason',p_data->>'reason','role',p_data->>'role','companies',p_data->'companies'));return '{"ok":true}';
 end if;
 perform public.pf_fail(404,'Operação não encontrada.');return null;
end$$;
revoke all on function public.pf_service(text,jsonb) from public,anon,authenticated;
grant execute on function public.pf_service(text,jsonb) to service_role;

-- Armazenamento privado de comprovantes. As regras são verificadas também no
-- acesso direto ao Storage; nenhum arquivo recebe URL pública.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('pf-evidence','pf-evidence',false,8388608,array['application/pdf','image/png','image/jpeg','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']) on conflict(id) do update set public=false,file_size_limit=8388608,allowed_mime_types=excluded.allowed_mime_types;
create or replace function public.pf_evidence_access(object_name text,for_write boolean default false) returns boolean language sql stable security definer set search_path=public,pg_temp as $$select exists(select 1 from public.pf_tasks t where t.id::text=(string_to_array(object_name,'/'))[2] and t.company=(string_to_array(object_name,'/'))[1] and array_length(string_to_array(object_name,'/'),1)=3 and public.pf_can_task(t.id) and (not for_write or t.status<>'resolved'))$$;
revoke all on function public.pf_evidence_access(text,boolean) from public,anon;
grant execute on function public.pf_evidence_access(text,boolean) to authenticated;
drop policy if exists pf_evidence_read on storage.objects;
create policy pf_evidence_read on storage.objects for select to authenticated using(bucket_id='pf-evidence' and public.pf_evidence_access(name,false));
drop policy if exists pf_evidence_insert on storage.objects;
create policy pf_evidence_insert on storage.objects for insert to authenticated with check(bucket_id='pf-evidence' and public.pf_evidence_access(name,true));
-- Restrições adicionais impedem que políticas amplas de outro bucket liberem
-- inadvertidamente os comprovantes deste sistema. Outros buckets não são alterados.
drop policy if exists pf_evidence_guard_read on storage.objects;
create policy pf_evidence_guard_read on storage.objects as restrictive for select to authenticated using(bucket_id<>'pf-evidence' or public.pf_evidence_access(name,false));
drop policy if exists pf_evidence_guard_insert on storage.objects;
create policy pf_evidence_guard_insert on storage.objects as restrictive for insert to authenticated with check(bucket_id<>'pf-evidence' or public.pf_evidence_access(name,true));
drop policy if exists pf_evidence_guard_update on storage.objects;
create policy pf_evidence_guard_update on storage.objects as restrictive for update to authenticated using(bucket_id<>'pf-evidence') with check(bucket_id<>'pf-evidence');
drop policy if exists pf_evidence_guard_delete on storage.objects;
create policy pf_evidence_guard_delete on storage.objects as restrictive for delete to authenticated using(bucket_id<>'pf-evidence');
drop policy if exists pf_evidence_guard_anon on storage.objects;
create policy pf_evidence_guard_anon on storage.objects as restrictive for all to anon using(bucket_id<>'pf-evidence') with check(bucket_id<>'pf-evidence');
-- Sem política UPDATE/DELETE para usuários: comprovantes e trilha ficam preservados.
commit;
