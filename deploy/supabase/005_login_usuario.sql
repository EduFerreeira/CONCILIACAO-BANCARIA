-- Atualização para login por nome de usuário. Não exige e-mail pessoal.
begin;
alter table public.pf_users add column if not exists login text;
create unique index if not exists pf_users_login_unique on public.pf_users(lower(login));
with missing as(select id,role,row_number() over(order by case when role='admin' then 0 else 1 end,created_at,id) rn from public.pf_users where login is null)
update public.pf_users u set login=case when m.rn=1 and m.role='admin' and not exists(select 1 from public.pf_users where lower(login)='administrador') then 'administrador' else 'usuario-'||replace(u.id::text,'-','') end from missing m where u.id=m.id;
create or replace function public.pf_user_json(user_id uuid) returns jsonb language sql stable security definer set search_path=public,pg_temp as $$select jsonb_build_object('id',u.id,'name',u.name,'login',u.login,'email',u.email,'role',u.role,'active',u.active,'must_change',u.must_change,'companies',coalesce((select jsonb_agg(company order by company) from public.pf_memberships where user_id=u.id),'[]'::jsonb)) from public.pf_users u where u.id=user_id$$;
revoke all on function public.pf_user_json(uuid) from public,anon,authenticated;
create or replace function public.pf_identity(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_column
declare username text;target_id uuid;email_value text;result jsonb;
begin
 if coalesce(auth.role(),'')<>'service_role' then perform public.pf_fail(403,'Operação reservada ao servidor.');end if;
 username:=lower(trim(coalesce(p_data->>'login','')));
 if username!~'^[a-z0-9][a-z0-9._-]{2,49}$' then perform public.pf_fail(422,'Login: use de 3 a 50 letras sem acento, números, ponto, hífen ou sublinhado.');end if;
 if p_action='lookup' then select email into email_value from public.pf_users where lower(login)=username and active;return jsonb_build_object('email',email_value);end if;
 if p_action='bootstrap' then
  perform pg_advisory_xact_lock(191832414);
  if exists(select 1 from public.pf_users) then perform public.pf_fail(409,'O sistema já possui usuários. Entre com o administrador existente.');end if;
  target_id:=(p_data->>'user_id')::uuid;select email into email_value from auth.users where id=target_id;
  if email_value is null then perform public.pf_fail(422,'Identificação de autenticação inválida.');end if;
  insert into public.pf_users(id,name,email,role,must_change,login) values(target_id,coalesce(nullif(trim(p_data->>'name'),''),'Administrador'),email_value,'admin',false,username);
  insert into public.pf_memberships values(target_id,'ponto'),(target_id,'agricola'),(target_id,'mutuo');
  perform public.pf_event(target_id,'initial_admin_created',jsonb_build_object('login',username));return jsonb_build_object('id',target_id);
 end if;
 if p_action='user_create' then
  if exists(select 1 from public.pf_users where lower(login)=username) then perform public.pf_fail(409,'Este login já está cadastrado.');end if;
  result:=public.pf_service('user_create',p_data);
  update public.pf_users set login=username where id=(p_data->>'user_id')::uuid;
  return result;
 end if;
 perform public.pf_fail(404,'Operação não encontrada.');return null;
end$$;
revoke all on function public.pf_identity(text,jsonb) from public,anon,authenticated;
grant execute on function public.pf_identity(text,jsonb) to service_role;
commit;
