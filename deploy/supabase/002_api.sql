begin;
create or replace function public.pf_api(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_column
declare actor public.pf_users;w public.pf_workspaces;t public.pf_tasks;old_t public.pf_tasks;target public.pf_users;doc jsonb;old_doc jsonb;item jsonb;r jsonb;a jsonb;b jsonb;dates jsonb;col text;lock_month text;company_id text;task_id uuid;role_name text;signature text;key text;occurrence integer;pending_ids jsonb;active_keys text[]:=array[]::text[];count_pending integer:=0;new_status text;new_assignee uuid;new_due date;new_note text;reason text;result jsonb;reviewer_id uuid;next_version integer;submission uuid;sub_version integer;expected integer;
begin
 actor:=public.pf_actor(p_action not in ('me','logout'));
 if p_action='me' then return jsonb_build_object('user',public.pf_user_json(actor.id),'companies',(select coalesce(jsonb_object_agg(m.company,case m.company when 'ponto' then 'PONTO FORTE' when 'agricola' then 'AGRÍCOLA FORTE' else 'MÚTUO' end),'{}') from public.pf_memberships m where user_id=actor.id));end if;
 if p_action='logout' then delete from public.pf_sessions where user_id=actor.id and session_id::text=auth.jwt()->>'session_id';return '{"ok":true}';end if;
 company_id:=p_data->>'company';
 if p_action in ('workspace_get','workspace_save','pending_sync') then
  if actor.role not in ('admin','reviewer') or not public.pf_can_company(company_id) then perform public.pf_fail(403,'Sem acesso a esta empresa ou operação.');end if;
  select * into w from public.pf_workspaces where company=company_id for update;
  if p_action='workspace_get' then return jsonb_build_object('version',w.version,'document',w.document);end if;
  if (p_data->>'version')::integer is distinct from w.version then perform public.pf_fail(409,'Outra pessoa alterou esta empresa. Atualize a página; os dados do servidor foram preservados.');end if;
  if p_action='workspace_save' then
   doc:=p_data->'document';old_doc:=w.document;
   if jsonb_typeof(doc)<>'object' or coalesce(doc->>'version','')<>'1' or coalesce(doc->>'workspaceId',company_id)<>company_id then perform public.pf_fail(422,'Dados de empresa inválidos.');end if;
   foreach col in array array['accounts','transactions','applications','importedBalances','statementNotices','periodClosures'] loop
    if jsonb_typeof(coalesce(doc->col,'[]'))<>'array' then perform public.pf_fail(422,'Estrutura financeira inválida.');end if;
   end loop;
   if doc->'accounts' is null or doc->'transactions' is null then perform public.pf_fail(422,'Contas e movimentos obrigatórios.');end if;
   if exists(select 1 from jsonb_array_elements(doc->'accounts') x where jsonb_typeof(x)<>'object' or coalesce(x->>'id','')='' or coalesce(x->>'name','')='') or (select count(*) from jsonb_array_elements(doc->'accounts'))<>(select count(distinct x->>'id') from jsonb_array_elements(doc->'accounts') x) then perform public.pf_fail(422,'Conta inválida.');end if;
   for item in select value from jsonb_array_elements((doc->'transactions')||coalesce(doc->'importedBalances','[]')) loop
    if coalesce(item->>'id','')='' or not exists(select 1 from jsonb_array_elements(doc->'accounts') x where x->>'id'=item->>'account') or coalesce(item->>'cents','')!~'^-?[0-9]+$' or abs((item->>'cents')::numeric)>9007199254740991 or coalesce(item->>'side','') not in ('bank','system') or coalesce(item->>'date','')!~'^\d{4}-\d{2}-\d{2}$' then perform public.pf_fail(422,'Movimento ou saldo inválido.');end if;
    perform (item->>'date')::date;
   end loop;
   if (select count(*) from jsonb_array_elements((doc->'transactions')||coalesce(doc->'importedBalances','[]')))<>(select count(distinct x->>'id') from jsonb_array_elements((doc->'transactions')||coalesce(doc->'importedBalances','[]')) x) then perform public.pf_fail(422,'Identificadores de lançamentos duplicados.');end if;
   for item in select value from jsonb_array_elements(coalesce(doc->'periodClosures','[]')) loop
    if coalesce(item->>'month','')!~'^\d{4}-(0[1-9]|1[0-2])$' or item->>'status' not in ('closed','reopened') or length(trim(coalesce(item->>'reason','')))=0 then perform public.pf_fail(422,'Fechamento inválido.');end if;
   end loop;
   select max(value->>'month') into lock_month from jsonb_array_elements(coalesce(old_doc->'periodClosures','[]')) where value->>'status'='closed';
   if lock_month is not null then
    foreach col in array array['accounts','transactions','importedBalances','applications','statementNotices','statementAnnotations','applicationNoMovement','temporaryAdjustments'] loop
     for r in select jsonb_build_object('a',aa.value,'b',bb.value) from jsonb_array_elements(coalesce(old_doc->col,'[]')) aa full join jsonb_array_elements(coalesce(doc->col,'[]')) bb on aa.value->>'id'=bb.value->>'id' where aa.value is distinct from bb.value loop
      foreach key in array array['a','b'] loop
       item:=r->key;
       if item is not null and item<>'null'::jsonb then
        dates:=jsonb_build_array(item->>'date',item->>'openingDate',item->>'systemDate',item->>'bankDate',item->>'month',item->'first'->>'date',item->'second'->>'date');
        if exists(select 1 from jsonb_array_elements_text(dates) d where d is not null and left(d,7)<=lock_month) then perform public.pf_fail(409,'Competência fechada. Reabra o mês com motivo antes de alterar dados.');end if;
       end if;
      end loop;
     end loop;
    end loop;
    for item in select value from jsonb_array_elements(coalesce(old_doc->'periodClosures','[]')) where value->>'status'='closed' loop
     if not exists(select 1 from jsonb_array_elements(coalesce(doc->'periodClosures','[]')) n where n->>'month'=item->>'month' and n->>'status' in ('closed','reopened') and length(trim(n->>'reason'))>0) then perform public.pf_fail(422,'Não remova o fechamento. Reabra com motivo.');end if;
    end loop;
   end if;
   update public.pf_workspaces set document=doc||jsonb_build_object('workspaceId',company_id),version=version+1,updated_by=actor.id,updated_at=now() where company=company_id returning version into next_version;
   perform public.pf_event(actor.id,'workspace_saved',jsonb_build_object('version',next_version,'previous_version',w.version),company_id);
   return jsonb_build_object('version',next_version);
  end if;
  if company_id='mutuo' then perform public.pf_fail(422,'A fila recebe movimentos pendentes de contas correntes. Mútuo mantém conferência própria.');end if;
  pending_ids:=p_data->'transaction_ids';
  if jsonb_typeof(pending_ids) is distinct from 'array' then perform public.pf_fail(422,'Lista de pendências inválida.');end if;
  if jsonb_array_length(pending_ids)>100000 or exists(select 1 from jsonb_array_elements(pending_ids) x where jsonb_typeof(x)<>'string') or jsonb_array_length(pending_ids)<>(select count(distinct value) from jsonb_array_elements_text(pending_ids)) then perform public.pf_fail(422,'Lista de pendências inválida.');end if;
  if exists(select 1 from jsonb_array_elements_text(pending_ids) id where not exists(select 1 from jsonb_array_elements(w.document->'transactions') x where x->>'id'=id)) then perform public.pf_fail(422,'Pendência não pertence à versão financeira salva.');end if;
  -- A chave inclui ocorrência, mantendo lançamentos repetidos distintos e reimportações estáveis.
  for r in select jsonb_build_object('row',x.value,'occurrence',row_number() over(partition by x.value->>'side',x.value->>'account',x.value->>'date',x.value->>'cents',regexp_replace(lower(translate(x.value->>'description','áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc')),'\s+',' ','g') order by x.ordinality)-1) from jsonb_array_elements(w.document->'transactions') with ordinality x loop
   item:=r->'row';if not pending_ids ? (item->>'id') then continue;end if;
   select value into a from jsonb_array_elements(w.document->'accounts') where value->>'id'=item->>'account';
   if a->>'kind'='application' or item->>'kind'='application' then perform public.pf_fail(422,'A fila recebe somente contas correntes.');end if;
   key:=encode(sha256(convert_to(jsonb_build_array(item->>'side',item->>'account',item->>'date',item->'cents',trim(regexp_replace(lower(translate(item->>'description','áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc')),'\s+',' ','g')),r->'occurrence')::text,'UTF8')),'hex');
   active_keys:=array_append(active_keys,key);
  end loop;
  signature:=encode(sha256(convert_to((select coalesce(jsonb_agg(k order by k),'[]')::text from unnest(active_keys) k),'UTF8')),'hex');
  if w.sync_version=w.version and w.sync_digest is distinct from signature then perform public.pf_fail(409,'Esta versão já foi apurada. Reimporte/corrija e salve uma nova versão.');end if;
  count_pending:=0;
  for r in select jsonb_build_object('row',x.value,'occurrence',row_number() over(partition by x.value->>'side',x.value->>'account',x.value->>'date',x.value->>'cents',regexp_replace(lower(translate(x.value->>'description','áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc')),'\s+',' ','g') order by x.ordinality)-1) from jsonb_array_elements(w.document->'transactions') with ordinality x loop
   item:=r->'row';if not pending_ids ? (item->>'id') then continue;end if;
   select value into a from jsonb_array_elements(w.document->'accounts') where value->>'id'=item->>'account';
   key:=encode(sha256(convert_to(jsonb_build_array(item->>'side',item->>'account',item->>'date',item->'cents',trim(regexp_replace(lower(translate(item->>'description','áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc')),'\s+',' ','g')),r->'occurrence')::text,'UTF8')),'hex');
   select * into old_t from public.pf_tasks where company=company_id and financial_key=key for update;
   if old_t.id is null then
    insert into public.pf_tasks(company,financial_key,account,account_name,date,description,cents,side,missing_in,reference,reconciliation_version) values(company_id,key,item->>'account',a->>'name',(item->>'date')::date,coalesce(item->>'description',''),(item->>'cents')::bigint,item->>'side',case when item->>'side'='bank' then 'system' else 'bank' end,coalesce(item->>'reference',''),w.version) returning id into task_id;
    perform public.pf_event(actor.id,'task_created_from_reconciliation',jsonb_build_object('version',w.version),company_id,task_id);
   else
    task_id:=old_t.id;
    update public.pf_tasks set financial_present=true,reconciliation_version=w.version,status=case when old_t.status='resolved' or not old_t.financial_present then 'pending' else old_t.status end,version=version+case when old_t.status='resolved' or not old_t.financial_present then 1 else 0 end,account_name=a->>'name',description=coalesce(item->>'description',''),reference=coalesce(item->>'reference',''),updated_at=now() where id=task_id;
    if old_t.status='resolved' or not old_t.financial_present then perform public.pf_event(actor.id,'financial_difference_returned',jsonb_build_object('version',w.version),company_id,task_id);perform public.pf_notify(old_t.assignee,task_id,'A diferença voltou a aparecer na conciliação. Confira novamente.');end if;
   end if;
   count_pending:=count_pending+1;
  end loop;
  for old_t in select * from public.pf_tasks where company=company_id and not(financial_key=any(active_keys)) and reconciliation_version<>w.version for update loop
   update public.pf_tasks set financial_present=false,reconciliation_version=w.version,version=version+case when old_t.financial_present then 1 else 0 end,updated_at=now() where id=old_t.id;
   if old_t.financial_present then perform public.pf_event(actor.id,'financial_difference_cleared',jsonb_build_object('version',w.version),company_id,old_t.id);perform public.pf_notify(old_t.assignee,old_t.id,'O lançamento não consta mais como faltante. Envie a correção para conferência.');end if;
  end loop;
  update public.pf_workspaces set sync_version=w.version,sync_digest=signature where company=company_id;
  perform public.pf_event(actor.id,'pending_sync',jsonb_build_object('version',w.version,'pending',count_pending),company_id);
  return jsonb_build_object('pending',count_pending,'version',w.version);
 end if;
 if p_action='users_list' then
  if actor.role not in ('admin','reviewer') or (coalesce(company_id,'')='' and actor.role<>'admin') then perform public.pf_fail(403,'Sem permissão.');end if;
  if coalesce(company_id,'')<>'' and not public.pf_can_company(company_id) then perform public.pf_fail(403,'Sem acesso a esta empresa.');end if;
  return jsonb_build_object('users',(select coalesce(jsonb_agg(public.pf_user_json(u.id) order by u.name),'[]') from public.pf_users u where (coalesce(company_id,'')='' and not exists(select 1 from public.pf_memberships m where m.user_id=u.id and not public.pf_can_company(m.company))) or exists(select 1 from public.pf_memberships m where m.user_id=u.id and m.company=company_id)));
 end if;
 if p_action='tasks_list' then
  if coalesce(company_id,'')<>'' and not public.pf_can_company(company_id) then perform public.pf_fail(403,'Sem acesso a esta empresa.');end if;
  if coalesce(p_data->>'month','')<>'' and (p_data->>'month')!~'^\d{4}-(0[1-9]|1[0-2])$' then perform public.pf_fail(422,'Competência inválida.');end if;
  if coalesce(p_data->>'status','') not in ('','active','pending','in_progress','waiting_document','awaiting_review','resolved') then perform public.pf_fail(422,'Situação inválida.');end if;
  return jsonb_build_object('tasks',(select coalesce(jsonb_agg(public.pf_task_json(t.id) order by t.due_date nulls last,t.date,t.id),'[]') from public.pf_tasks t where public.pf_can_task(t.id) and (coalesce(company_id,'')='' or t.company=company_id) and (coalesce(p_data->>'month','')='' or to_char(t.date,'YYYY-MM')=p_data->>'month') and (not coalesce((p_data->>'mine')::boolean,false) or t.assignee=actor.id) and (coalesce(p_data->>'status','')='' or p_data->>'status'='active' and t.status<>'resolved' or t.status=p_data->>'status')));
 end if;
 if p_action in ('task_get','task_action','attachment_add') then
  task_id:=(p_data->>'task_id')::uuid;if p_action='task_action' then perform 1 from public.pf_workspaces where company=(select company from public.pf_tasks where id=task_id) for update;end if;select * into t from public.pf_tasks where id=task_id for update;
  if t.id is null then perform public.pf_fail(404,'Pendência não encontrada.');end if;
  if not public.pf_can_task(task_id) then perform public.pf_fail(403,'Esta pendência não está atribuída a você ou sua empresa.');end if;
  if p_action='task_get' then return jsonb_build_object('task',public.pf_task_json(task_id),'events',(select coalesce(jsonb_agg(to_jsonb(e)-'actor_id' order by e.created_at,e.id),'[]') from public.pf_events e where e.task_id=t.id),'attachments',(select coalesce(jsonb_agg(to_jsonb(f)-'storage_name'-'uploaded_by' order by f.created_at),'[]') from public.pf_attachments f where f.task_id=t.id));end if;
  if p_action='attachment_add' then
   if t.status='resolved' then perform public.pf_fail(409,'Pendência encerrada.');end if;
   if length(p_data->>'filename') not between 1 and 180 or (p_data->>'size')::integer not between 1 and 8388608 or left(p_data->>'storage_name',length(t.company||'/'||t.id::text||'/'))<>t.company||'/'||t.id::text||'/' then perform public.pf_fail(422,'Comprovante inválido.');end if;
   insert into public.pf_attachments(task_id,filename,media_type,size,storage_name,uploaded_by) values(t.id,p_data->>'filename',p_data->>'media_type',(p_data->>'size')::integer,p_data->>'storage_name',actor.id) returning id into reviewer_id;
   perform public.pf_event(actor.id,'attachment_added',jsonb_build_object('filename',p_data->>'filename','size',p_data->'size'),t.company,t.id);return jsonb_build_object('id',reviewer_id);
  end if;
  if (p_data->>'version')::integer is distinct from t.version then perform public.pf_fail(409,'Esta pendência mudou. Atualize antes de salvar.');end if;
  new_status:=t.status;new_assignee:=t.assignee;new_due:=t.due_date;new_note:=t.note;submission:=t.submitted_by;sub_version:=t.submitted_version;
  key:=p_data->>'action';reason:=trim(coalesce(p_data->>'reason',''));
  if key='assign' then
   if actor.role not in ('admin','reviewer') then perform public.pf_fail(403,'Sem permissão para atribuir.');end if;
   new_assignee:=nullif(p_data->>'assignee','')::uuid;new_due:=nullif(p_data->>'due_date','')::date;
   if new_assignee is not null and not exists(select 1 from public.pf_users u join public.pf_memberships m on m.user_id=u.id where u.id=new_assignee and u.active and m.company=t.company) then perform public.pf_fail(422,'Responsável sem acesso a esta empresa.');end if;
   perform public.pf_notify(new_assignee,t.id,'Você recebeu uma pendência: '||t.account_name);
  elsif key in ('progress','waiting','note','submit') then
   if t.status='resolved' then perform public.pf_fail(409,'Pendência encerrada. Reabra antes de alterar.');end if;
   new_note:=trim(coalesce(p_data->>'note',''));reason:=new_note;
   if key='submit' then
    new_status:='awaiting_review';submission:=actor.id;sub_version:=t.reconciliation_version;
    for reviewer_id in select u.id from public.pf_users u join public.pf_memberships m on m.user_id=u.id where m.company=t.company and u.active and u.role in ('admin','reviewer') and u.id<>actor.id loop perform public.pf_notify(reviewer_id,t.id,'Correção enviada para conferência: '||t.account_name);end loop;
   elsif key='progress' then new_status:='in_progress';elsif key='waiting' then new_status:='waiting_document';end if;
  elsif key in ('approve','return','reopen') then
   if actor.role not in ('admin','reviewer') then perform public.pf_fail(403,'Seu perfil não pode aprovar.');end if;
   if key='approve' then
    if t.status<>'awaiting_review' or t.submitted_by is null then perform public.pf_fail(409,'Envie a correção para conferência primeiro.');end if;
    if t.submitted_by=actor.id then perform public.pf_fail(403,'Outra pessoa deve aprovar sua correção.');end if;
    select * into w from public.pf_workspaces where company=t.company;
    if t.financial_present or t.reconciliation_version<>w.version or w.sync_version<>w.version then perform public.pf_fail(409,'Diferença ainda consta ou apuração desatualizada. Reimporte, salve e sincronize antes de encerrar.');end if;
    new_status:='resolved';
   else
    if key='return' and t.status<>'awaiting_review' then perform public.pf_fail(409,'Não está aguardando conferência.');end if;
    new_status:='pending';submission:=null;sub_version:=null;
   end if;
   perform public.pf_notify(t.assignee,t.id,'Conferência: '||case when key='approve' then 'pendência encerrada. ' else 'pendência devolvida. ' end||reason);
  else perform public.pf_fail(422,'Ação inválida.');end if;
  if length(reason) not between 1 and 5000 then perform public.pf_fail(422,'Informe observação ou justificativa.');end if;
  update public.pf_tasks set status=new_status,assignee=new_assignee,due_date=new_due,note=new_note,submitted_by=submission,submitted_version=sub_version,version=version+1,updated_at=now() where id=t.id;
  perform public.pf_event(actor.id,key,jsonb_build_object('reason',reason,'before',jsonb_build_object('status',t.status,'assignee',t.assignee,'due_date',t.due_date,'note',t.note),'after',jsonb_build_object('status',new_status,'assignee',new_assignee,'due_date',new_due,'note',new_note)),t.company,t.id);
  return jsonb_build_object('task',public.pf_task_json(t.id));
 end if;
 if p_action='attachment_get' then
  select to_jsonb(f) into result from public.pf_attachments f where id=(p_data->>'attachment_id')::uuid;
  if result is null then perform public.pf_fail(404,'Comprovante não encontrado.');end if;
  if not public.pf_can_task((result->>'task_id')::uuid) then perform public.pf_fail(403,'Sem acesso a este comprovante.');end if;return result;
 end if;
 if p_action='notifications_list' then return jsonb_build_object('notifications',(select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc),'[]') from (select * from public.pf_notifications where user_id=actor.id and public.pf_can_task(task_id) order by created_at desc limit 100) n));end if;
 if p_action='notifications_read' then update public.pf_notifications set read_at=now() where user_id=actor.id and read_at is null and public.pf_can_task(task_id);return '{"ok":true}';end if;
 perform public.pf_fail(404,'Operação não encontrada.');return null;
end$$;
revoke all on function public.pf_api(text,jsonb) from public,anon;
grant execute on function public.pf_api(text,jsonb) to authenticated;
commit;
