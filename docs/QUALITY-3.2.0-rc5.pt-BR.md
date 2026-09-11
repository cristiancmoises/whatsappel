# WhatsAppel 3.2.0-rc5 — qualidade, desempenho e segurança

Esta rodada altera workers Python, auditoria, instalação, testes e documentação.
No Emacs, muda apenas a identificação da versão. A interface RC4 e o bridge são
mantidos; não há nova alegação de validação gráfica, alteração no wuzapi ou pqenv.

O novo módulo compartilhado rejeita chaves JSON duplicadas, NaN/Infinity e overflow,
profundidade superior a 96, UTF-8 inválido e substitutos Unicode sem par. O upload
passa a usar as mesmas regras estritas das leituras. Uma resposta contraditória ou
perdida mantém o envio como incerto, sem repetição automática. Aceitação pelo
upstream não comprova entrega ao destinatário.

O POST e a leitura da resposta de upload têm prazo total na thread principal do
worker POSIX, além do timeout do socket. Preparar o arquivo/payload ocorre antes.
Outras plataformas/threads dependem dos limites do socket e do processo pai.
Os tokens continuam pela entrada padrão, não por argumentos, URLs ou arquivos.

Leituras aprovadas na validação encaminham o JSON original no envelope sem uma
segunda serialização. Limites, validação e proteção de respostas de erro permanecem.
O hash SHA-256 usa blocos fixos, sem carregar o arquivo inteiro de uma vez.
As medições isoladas não representam o tempo completo de abrir uma conversa.

## Auditoria sem transformar lacunas em sucesso

O runner retorna PASS/0 somente para cobertura completa, FAIL/1 para falhas e
PARTIAL/2 quando há testes ignorados ou falhas esperadas. Descobrir zero testes é
falha. As contagens vêm dos resultados observados, inclusive skips de classe e
subtestes. `make audit` usa o controlador completo; alvos Python usam o runner.

Cada comando auditado tem log privado 0600, limite de 8 MiB e prazo de 600 segundos.
Exceder um limite falha a etapa. Grupos de processos POSIX pertencentes ao comando
são encerrados; processos que criam sessões independentes não estão cobertos.
Variáveis comuns de segredo são removidas, mas testes continuam código confiável
executado com os direitos do usuário. Isso não constitui um sandbox.

## Verificar e instalar em fish

O pacote cumulativo aceita somente hashes registrados da cadeia retida
3.1/RC1/RC2/RC3/RC4. Houve variantes anteriores de RC3: uma versão não registrada
será recusada. O HEAD atual dos remotos não foi confirmado.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc5.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc5.tar.gz
and cd whatsappel-update-3.2.0-rc5
and python3 scripts/update-package.py "$HOME/whatsappel"
and python3 scripts/update-package.py "$HOME/whatsappel" --audit-only --full-audit
```

Nenhum desses comandos substitui a instalação. O segundo modo de auditoria cria
uma candidata isolada e executa duas passagens completas. São necessários Python,
Emacs, Guile/JSON, fish, mpv e FFmpeg; o escopo completo inclui Rust/Cargo. A falta de
ferramentas e resultados parciais impedem a aprovação. Depois de aprovação nativa:

```fish
fish scripts/install-local.fish "$HOME/whatsappel" --full-audit
```

O instalador repete os testes, exige dois relatórios distintos e completos, confere
escopo, etapas e hashes antes/depois, verifica documentos e alterações concorrentes
no destino, e instala os bytes imutáveis da candidata — não relê um download que
pode ter mudado. Hashes/relatórios não são assinatura nem proteção contra um atacante
com os mesmos privilégios locais.

Preserva configuração, sessões, pareamento, arquivos originais e código PQ mais
novo. O backup privado e o comando exato de rollback são impressos após sucesso;
rollback recusa sobrescrever alterações posteriores. Reinicie o Emacs. RC4→RC5
não altera o bridge; vindo de antes de RC2, reinicie seu serviço real do bridge
para ativar a atualização anterior. Serviços, Docker, portas e NPM não são adivinhados.

Os scripts de publicação e IONOS permanecem, com porta SSH 5119 e host key
verificado, tokens ocultos e worktree isolada `~/whatsappel-publish-3.2.0-rc5`.
Nenhum deploy, push ou envio real foi executado nesta rodada. Consulte o guia em
inglês para os comandos completos e as limitações das medições.

A liberação continua candidata até executar testes nativos e validar interação
visual, microfone físico, mpv, sincronização e entrega em conta real. A auditoria
registra exatamente o que passou, foi parcial, falhou ou ficou bloqueado.
