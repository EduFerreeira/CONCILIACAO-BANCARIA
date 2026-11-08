# PONTO FORTE • Supabase + Cloudflare Pages

Configuração preparada para:

- Supabase: https://kynjbbdsfkuqjrihjdmj.supabase.co
- Cloudflare Pages: https://conciliacao-bancaria-ebt.pages.dev/
- Nome do projeto Pages: `conciliacao-bancaria-ebt`

Versão preparada para implantação, sem publicação automática. O endereço público só passa a existir depois da configuração dos seus projetos.

## Estrutura

- **Cloudflare Pages em modo avançado (`_worker.js`):** portal, interface financeira e API na mesma origem HTTPS do seu Pages. Não é necessário criar um Worker separado nem hospedar um servidor Python.
- **Supabase Auth:** autenticação de login/senha, criação pelo administrador, troca obrigatória da senha temporária e recuperação pelo administrador.
- **Supabase PostgreSQL:** empresas, perfis, fila, responsáveis, prazos, aprovação e histórico, com funções de acesso controladas e tabelas privadas.
- **Supabase Storage:** bucket privado de comprovantes com regras por empresa e responsável, inclusive no acesso direto ao Storage.

O perfil Responsável vê somente suas pendências e comprovantes; Conferente e Administrador acessam somente as empresas permitidas. O administrador cadastra, altera perfil/empresas, desativa e redefine senha. Alterar acesso encerra as sessões do usuário.

Observações são salvas automaticamente; responsáveis enviam a correção para conferência. Outra pessoa deve aprovar. A API bloqueia o encerramento se a diferença ainda constar ou se a apuração estiver desatualizada. O lançamento continua sendo corrigido no SIAGRI/banco e reimportado pelo conferente; não existe escrita automática no SIAGRI.

A conciliação financeira usa o motor do HTML no navegador autorizado do conferente. Ao salvar, os dados são gravados com controle de versão e a apuração é enviada à fila. O banco valida o perfil, a versão, os identificadores dos lançamentos, a empresa e a consistência da apuração por versão. Responsáveis não podem enviar apurações nem mudar a base financeira. Alterações simultâneas não sobrescrevem silenciosamente dados de outro conferente.

## 1. Criar/configurar o projeto Supabase

Use um projeto dedicado para este sistema. No SQL Editor, execute em ordem:

1. `deploy/supabase/001_schema.sql`
2. `deploy/supabase/002_api.sql`
3. `deploy/supabase/003_service_storage.sql`
4. `deploy/supabase/005_login_usuario.sql`

Os scripts não apagam dados existentes da aplicação. As tabelas possuem prefixo `pf_`; o bucket é `pf-evidence`, privado.

Em Authentication, mantenha o provedor de e-mail/senha habilitado e desabilite o cadastro público de novos usuários. O administrador cria os acessos pelo portal. Não é preciso configurar envio de convites: o portal mostra uma senha temporária uma vez, para entrega por canal reservado, e obriga sua troca.

### Primeiro administrador: login e senha, sem e-mail pessoal

O portal usa **nome de usuário e senha**, por exemplo `administrador`. O identificador técnico exigido internamente pelo Supabase é gerado automaticamente pelo servidor; as pessoas não precisam informar e-mail no acesso ou no cadastro.

1. Execute os scripts 001, 002, 003 e **005**. Se 001–003 já foram executados, aplique apenas o novo `005_login_usuario.sql`.
2. Nos Secrets do Pages, além das duas chaves Supabase, cadastre `FIRST_ADMIN_SETUP_CODE` com um código reservado escolhido por você, de pelo menos 24 caracteres.
3. Após publicar a versão atualizada, abra o portal e clique em **Configurar o primeiro administrador**.
4. Informe esse código reservado, escolha o login (por exemplo `administrador`) e crie sua senha com pelo menos 12 caracteres.
5. A criação funciona uma única vez enquanto não há usuários cadastrados no sistema. Depois use **Usuários e acessos** para criar os demais logins. Você pode remover o Secret de ativação após concluir.

Se já existia um administrador no banco, a atualização 005 atribui `administrador` ao primeiro administrador sem login definido e preserva a senha existente. Consulte a coluna `login` em `pf_users` para confirmar. Usuários anteriores recebem um identificador único; não são apagados.

O arquivo 004 é apenas uma alternativa manual por UID para o proprietário técnico. **Não é necessário preencher e-mail no SQL.**

## 2. Preparar o seu Cloudflare Pages

O pacote está ajustado para o projeto **conciliacao-bancaria-ebt**. As duas URLs públicas já estão no arquivo `deploy/pages/wrangler.toml`; nenhuma chave secreta foi incluída.

Requer Node.js 22 ou superior. Na pasta descompactada:

```sh
cd deploy/pages
npm ci
npm run prepare
npm run check
```

A preparação gera `deploy/pages/dist/`, incluindo o portal, os importadores e `_worker.js`. O arquivo `_routes.json` encaminha todas as rotas à API, protegendo o HTML financeiro. Não retire esses dois arquivos.

### Cadastrar as duas chaves no Pages

No painel Cloudflare → Workers & Pages → **conciliacao-bancaria-ebt** → Settings → Variables and Secrets, cadastre na produção:

- `SUPABASE_ANON_KEY`: chave anon/publishable do seu projeto Supabase.
- `SUPABASE_SERVICE_ROLE_KEY`: chave service_role/secret do seu projeto, armazenada como **Secret**.
- `FIRST_ADMIN_SETUP_CODE`: código reservado de pelo menos 24 caracteres, usado apenas para a criação inicial do administrador.

Nunca coloque a chave administrativa no HTML, Git, mensagens ou capturas de tela. O servidor a utiliza apenas para provisionar/revogar logins e registrar sessões; os acessos financeiros e de pendências usam o JWT do usuário e as verificações SQL.

Também é possível cadastrar pelo terminal, autenticado em sua conta Cloudflare:

```sh
npx wrangler login
npx wrangler pages secret put SUPABASE_ANON_KEY --project-name conciliacao-bancaria-ebt
npx wrangler pages secret put SUPABASE_SERVICE_ROLE_KEY --project-name conciliacao-bancaria-ebt
npx wrangler pages secret put FIRST_ADMIN_SETUP_CODE --project-name conciliacao-bancaria-ebt
```

Cada comando pede a chave ou o código reservado no terminal. Não escreva o valor no comando nem o envie pelo chat. As chaves não são embutidas no frontend.

### Publicação — etapa separada, ainda não executada

A publicação substituirá a interface atual do Pages por uma tela de login. Guarde o backup financeiro e a versão anterior do site e revise o pacote antes de publicar.

Se o projeto estiver conectado ao Git, use:

- Comando de build: `npm ci --prefix deploy/pages && npm run prepare --prefix deploy/pages`
- Diretório de saída: `deploy/pages/dist`

Se usar Wrangler, confira no painel qual é a branch de produção e então publique com essa branch explicitamente:

```sh
npx wrangler pages deploy dist --project-name conciliacao-bancaria-ebt --branch NOME_DA_BRANCH_DE_PRODUCAO
```

Substitua `NOME_DA_BRANCH_DE_PRODUCAO` pela branch real; não execute o comando literalmente. Nenhum desses comandos de publicação foi executado neste trabalho.

A origem de produção já está configurada como `https://conciliacao-bancaria-ebt.pages.dev`. Se adotar domínio próprio, atualize `PUBLIC_ORIGIN` no arquivo de configuração. Para prévias, a origem e o Supabase de teste devem ser configurados separadamente.

Em Supabase Authentication → URL Configuration, use o endereço do Pages como Site URL. Mantenha o cadastro público desativado, pois os usuários serão criados pelo administrador do portal.

Para importações grandes, verifique os limites de CPU/memória do plano Pages Functions/Workers. Cada requisição JSON da API permite até 16 MB; comprovantes aceitam até 8 MB por arquivo. A conexão real e as permissões precisam ser conferidas no seu projeto depois das migrações e da configuração dos segredos.

## 3. Levar os dados do HTML atual

1. No HTML antigo, exporte **Backup desta empresa / área** e guarde uma cópia intacta.
2. Entre no portal online com o administrador e clique em **Conciliação bancária**.
3. Selecione a empresa correta e restaure o backup dela em **Backup e exportação**.
4. Aguarde **Salvo no servidor**. Clique em **Sincronizar pendências com a equipe** para conferir o envio inicial. Depois de novas gravações, a fila também é sincronizada automaticamente.
5. Repita para cada empresa autorizada.
6. No portal, crie os logins e atribua responsáveis e prazos.

O backup consolidado online inclui somente as empresas autorizadas ao login. A restauração é feita por empresa: para restaurar um backup consolidado antigo, extraia o objeto `workspaces.ponto`, `workspaces.agricola` ou `workspaces.mutuo` para um JSON individual e restaure na empresa correspondente. Não restaure dados de uma empresa em outra.

**Não apague o HTML ou os backups antigos antes de conferir a migração.** O portal online não lê automaticamente o navegador de cada computador e não modifica o armazenamento do HTML antigo.

## 4. Rotina das pessoas

- **Administrador:** cria acessos, define empresas e perfis, atribui responsáveis e prazos. Senhas temporárias são entregues por canal reservado; a aplicação não envia e-mail/WhatsApp automaticamente.
- **Responsável:** entra na sua fila, registra providência, anexa comprovante e envia para conferência. Os avisos aparecem no próprio login, com atualização a cada 30 segundos.
- **Conferente:** reimporta o relatório/extrato corrigido, salva, sincroniza e confere a resolução. Pode aprovar ou devolver com justificativa.
- **Histórico:** registra quem alterou, quando, o motivo, o estado anterior/novo e os anexos. Não há exclusão de eventos/comprovantes por usuários comuns.

A fila inicial recebe os movimentos pendentes de **contas correntes**, conforme a aba Pendências existente. Aplicações e Mútuo mantêm suas conferências financeiras próprias; não são criadas pendências artificiais por diferença herdada de saldo.

## 5. Sessões e acesso

Cookies HttpOnly, Secure em HTTPS, SameSite=Lax, validação de origem e token CSRF. As sessões do sistema duram até 8 horas. Redefinição de senha, desativação ou mudança de acesso revogam as sessões da aplicação, inclusive para JWTs ainda não expirados. As regras de Storage também verificam essa sessão.

Não há cadastro público, senha padrão ou chave administrativa embutida no frontend. O primeiro administrador deve ser criado pelo proprietário do projeto. Guarde uma conta administrativa adicional para recuperação.

## 6. Backup e operação

O JSON do HTML cobre os dados financeiros, mas **não inclui** os usuários do Supabase Auth, as atribuições da equipe e os comprovantes. Configure backup do PostgreSQL/Auth e cópia do bucket privado `pf-evidence` conforme o plano do Supabase. Faça também exportações financeiras antes de grandes reimportações.

Para recuperar o administrador sem outro administrador ativo, o proprietário do projeto pode redefinir a senha pelo Supabase Auth e executar no SQL Editor a exclusão das sessões desse usuário em `pf_sessions`, mantendo o perfil e as empresas. Não distribua acesso ao SQL Editor aos responsáveis comuns.

## Validação realizada

- Migrações executadas em PostgreSQL local em WebAssembly (PGlite), com papéis Auth/Storage simulados.
- Regras reais SQL: isolamento por usuário/empresa, privilégios das funções, acesso privado a comprovantes, apuração por versão, aprovação financeira, proibição de aprovação própria, reabertura por diferença recorrente, revogação e fechamento mensal.
- Navegadores separados com Worker e PostgreSQL locais: login, usuário temporário, troca de senha, atribuição, observação automática, anexo, nova apuração e aprovação por outra pessoa.
- Modo avançado do Cloudflare Pages executado localmente com a ferramenta oficial: ASSETS, login, rotas privadas e bloqueio do acesso direto ao HTML financeiro validados.
- As URLs públicas fornecidas já estão configuradas no pacote. O acesso aos serviços hospedados ainda depende das migrações e das chaves cadastradas como Secrets. Os serviços de autenticação/Storage foram simulados nos testes locais; isso não substitui o teste final na implantação real.

Testes SQL adicionais (não publicam):

```sh
cd deploy/pages
npm run test:sql
```
