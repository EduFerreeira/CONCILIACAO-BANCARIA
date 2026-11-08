-- MÉTODO MANUAL OPCIONAL. Prefira a criação do administrador pelo portal,
-- após executar 005_login_usuario.sql e configurar FIRST_ADMIN_SETUP_CODE.
-- Se usar este método, copie o UID do usuário em Authentication > Users.
-- Não coloque senha neste SQL e não traduza os comandos SQL.
do $$
declare administrator_id uuid:=null;administrator_login text:='administrador';internal_email text;
begin
 if administrator_id is null then raise exception 'Prefira Configurar o primeiro administrador no portal. Para o método manual, substitua null pelo UID entre aspas e execute primeiro 005_login_usuario.sql.';end if;
 if administrator_login!~'^[a-z0-9][a-z0-9._-]{2,49}$' then raise exception 'Login inválido.';end if;
 if exists(select 1 from public.pf_users where role='admin') then raise exception 'Já existe administrador. Entre com o login definido na tabela pf_users.';end if;
 select email into internal_email from auth.users where id=administrator_id;
 if internal_email is null then raise exception 'UID não encontrado no Authentication.';end if;
 insert into public.pf_users(id,name,email,role,must_change,login) values(administrator_id,'Administrador',internal_email,'admin',false,administrator_login);
 insert into public.pf_memberships(user_id,company) values(administrator_id,'ponto'),(administrator_id,'agricola'),(administrator_id,'mutuo');
 perform public.pf_event(administrator_id,'initial_admin_created',jsonb_build_object('login',administrator_login,'source','Configuração manual pelo proprietário'));
end$$;
