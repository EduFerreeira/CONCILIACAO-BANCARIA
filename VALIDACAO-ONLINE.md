# Validação da versão Supabase + Cloudflare

07/11/2026 • implementação preparada para revisão, sem publicação.

- Migrações 001–003 executadas e verificadas em PostgreSQL local em WebAssembly.
- Testes SQL: empresa, usuário, sessão temporária, funções privadas, versões, aprovação por outra pessoa, apuração financeira atualizada, reaparecimento, histórico, revogação de acesso e fechamento.
- Storage: comprovantes privados; usuário diferente não lê nem grava comprovante alheio, inclusive quando existe uma política de leitura ampla de outro bucket.
- Navegadores separados: administrador cadastra/atribui, responsável troca senha e trata, observação salva automaticamente, comprovante anexado, conferente reimporta e aprova.
- Troca de empresa carrega a versão atual do servidor e mantém os dados separados. Alteração de acesso revoga a sessão antiga.
- Nenhuma chave de administração ou token de sessão é incluído no HTML; cookies de autenticação são HttpOnly.
- Compilação: Wrangler 4.158.0, deploy --dry-run concluído, sem publicação.

Os serviços Auth/Storage foram simulados no teste local, usando as regras PostgreSQL reais. O teste final hospedado depende da vinculação dos projetos Supabase/Cloudflare, chaves cadastradas como Secrets e aplicação das migrações. Nenhuma conta, domínio ou banco remoto foi alterado. O HTML financeiro existente foi preservado.

## Configuração do projeto existente

- Supabase: https://kynjbbdsfkuqjrihjdmj.supabase.co
- Pages: https://conciliacao-bancaria-ebt.pages.dev/
- Projeto `conciliacao-bancaria-ebt` configurado em `deploy/pages/wrangler.toml`.
- Build em modo avançado com `_worker.js` e `_routes.json`; variáveis públicas configuradas, chaves ausentes por segurança.
- Runtime oficial Wrangler Pages validado localmente: login e assets servidos, API/financeiro sem sessão bloqueados, HTML financeiro e código de servidor sem acesso direto. Foram usadas chaves fictícias e nenhuma chamada ao Supabase real.
- Configuração de migrações, segredos e publicação nas contas reais ainda pendentes; o site existente não foi alterado.

## Login por nome de usuário

- Migração 005 acrescenta login único e preserva usuários/senhas existentes.
- Portal e cadastro usam nome de usuário, sem e-mail pessoal. Identificador de autenticação é criado automaticamente no servidor.
- Primeiro administrador pode ser criado na tela com código reservado FIRST_ADMIN_SETUP_CODE. Não há senha padrão; a pessoa escolhe a senha.
- Testes aprovaram código incorreto bloqueado, criação inicial, login sem diferenciar maiúsculas e minúsculas, bloqueio de nova ativação e limpeza do usuário técnico quando a ativação é recusada.
- Fluxo completo de atribuição, correção, comprovantes e aprovação novamente aprovado usando login por nome de usuário. Testes locais, sem alteração no site/Supabase publicado.
