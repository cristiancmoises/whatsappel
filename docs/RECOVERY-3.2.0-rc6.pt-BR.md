# RC6: corrigir os testes nativos e instalar com proteção

## Diagnóstico confirmado pelos arquivos enviados

Os dois passes RC5 registraram 19 verificações aprovadas e duas falhas. O ERT
executou 108 testes: 107 passaram. A suíte Guile teve 77 aprovações e uma falha.
Os 62 hashes de código dos relatórios coincidem com o candidato RC5 reconstruído.

O teste de histórico ainda procurava `Show older`, embora o botão fosse
`Load older`. O teste Guile usava a forma nomeada de `test-error` sem o argumento
explícito do tipo de erro. RC6 corrige os testes sem remover o limite de histórico,
sem aceitar configuração zero e sem transformar falhas em testes ignorados.
O botão real agora é ativado pelo teste, com verificação da expansão e do rascunho.

Os resultados RC5 enviados não são resultados RC6. Consulte o relatório de
auditoria desta versão para separar verificações executadas das bloqueadas.

## Desempenho, uso e segurança

O polling passa a percorrer janelas de frames visíveis, sem varrer todos os buffers
do Emacs. Exclui minibuffer, frames ocultos/minimizados e buffers em fechamento;
elimina duplicatas e preserva o intervalo de espera após falhas. Um erro síncrono
em um buffer não impede a atualização dos demais. Não foi medido ganho percentual
de velocidade da interface. Os mecanismos existentes de mídia, mpv e envio são
preservados, inclusive as limitações de operações antigas ainda síncronas.

A identidade dos botões é independente do texto visível. Foram adicionados testes
para ativação por Return, texto traduzido, janelas duplicadas e espera após falha.
Uma falha nativa mostra agora o nome do teste ou sua linha no terminal. O log
completo é preservado; o resumo não copia valores de asserções ou backtraces.

O launcher exige `.env` regular, privado e pertencente ao usuário. A leitura usa
um único descritor limitado, sem seguir links nem bloquear em FIFO. Arquivos
acessíveis por grupo/outros, UTF-8 inválido, tamanho excessivo, atribuições
reconhecidas duplicadas e substituições de shell são recusados. O arquivo nunca
é executado. A ausência de `.env` continua permitindo configuração no init do
Emacs; um arquivo existente inseguro não provoca troca silenciosa de configuração.

Para um `.env` regular do próprio usuário que precise de permissões privadas:

```fish
chmod 600 "$HOME/whatsappel/.env"
```

Isso muda permissões, não tokens. Não crie um `.env` apenas por usar configuração
no init. O modo `--quick` continua exigindo credenciais no ambiente/arquivo porque
não carrega o init. O instalador não altera configuração, sessões nem arquivos PQ.

## Instalação fish com dois passes completos

Baixe o pacote e checksum para Downloads. Use uma extração nova. O comando abaixo
executa duas auditorias completas e só então instala, se ambas forem aprovadas.
Não é necessário executar antes outros dois passes. Falhas, testes ignorados ou
ferramentas ausentes não liberam a instalação.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc6.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc6.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/install-local.fish" \
    "$HOME/whatsappel" --full-audit
```

Para auditar SEM instalar, use em vez do último comando:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/update-package.py" \
    "$HOME/whatsappel" --audit-only --full-audit
```

O pacote é cumulativo e aceita apenas hashes anteriores registrados. Não é
necessário instalar RC5 depois da falha. Alterações desconhecidas e variantes
RC3 não reconhecidas são preservadas por recusa. O HEAD remoto atual não foi
verificado nem presumido igual ao código retido.

## Inicialização e diagnóstico

Depois de instalar, reinicie a instância do Emacs e clique em WhatsAppel no menu,
ou execute `~/.local/bin/whatsappel`. A verificação local de configuração, sem
conectar à ponte nem enviar mensagens, é:

```fish
python3 "$HOME/whatsappel/scripts/launch-whatsappel.py" --check
```

RC5 para RC6 não muda a ponte. Uma instalação anterior à RC2 também recebe a ponte
da RC2 e precisa reiniciar seu processo real. O instalador não adivinha nomes de
serviços Shepherd/systemd/Docker. Atualizar só a VPS não atualiza o Emacs do laptop.

Para resumir os relatórios RC5 enviados sem executar testes novamente:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc6/scripts/audit-workspace.py" \
    --summarize "$HOME/whatsappel-audit-20260910T113901839093Z"
```

O retorno 1 é correto, pois esses relatórios antigos contêm falhas. Também pode
usar o diretório exato de uma nova auditoria. O resumo não executa comandos do
relatório nem segue seu campo `log`; não representa uma atestação independente.

## Reversão e publicação

Guarde o backup e o comando exato de rollback impressos após a instalação.
A reversão recusa sobrescrever mudanças posteriores. Os helpers de IONOS
`root@securityops.co:5119` e publicação nos quatro remotes continuam incluídos;
o novo worktree é `~/whatsappel-publish-3.2.0-rc6`. Tokens continuam ocultos e
não há force push. Não houve deploy, push, nova branch/tag/release ou mensagem real
nesta preparação. A autorização de CI anteriormente recusada não foi repetida.

Ainda são necessários testes nativos e aceitação real: botão de histórico por
mouse/Return, rascunho, rolagem, não lidas, mpv, microfone e entrega a destinatário
de teste autorizado. As limitações anteriores de voz, GIF e PQ permanecem.
