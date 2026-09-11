# RC9 — interface nativa, fotos e presença observada

**Candidata de atualização, não uma versão com validação nativa/real completa.**
A base é o pacote RC8 preservado, não uma suposição sobre o HEAD dos repositórios.
Consulte AUDIT-3.2.0-rc9.md para os resultados efetivamente executados.

## Uso

A interface continua sendo Emacs: tema preto/ciano local aos buffers, alternativa
que respeita seu tema atual, espaço reservado para avatar, painel de contato,
configurações, escala de fontes e botão Emoji. Não é um navegador ou Electron.
A abertura imediata da área de escrita e as proteções contra travamento da RC8
foram preservadas. Não há descriptografia automática adicional.

Clique na linha para abrir a conversa; no avatar ou **Contact info** para abrir
os detalhes. `i` na lista e `C-c i` na conversa abrem o painel; `q` volta.
**Larger photo** solicita uma prévia de 256 pixels, não o arquivo original da foto.
**Settings** controla fotos, cache em memória, consentimento de presença e tema.
`C-c e` insere um emoji sem enviar nada. `M-x whatsapp-profile-diagnostics` mostra
versão e contagens locais sem IDs, contatos, mensagens, URLs ou tokens.

## Presença sem informações inventadas

**Online** depende de evento positivo autorizado. **Offline** depende de evento
correspondente; sem informação recente, aparece **Status unavailable**. O prazo
máximo local é 60 segundos; digitação/gravação expira independentemente em 8 segundos.
Último acesso privado, ausente, zero ou futuro não é deduzido de mensagens.
Grupos não recebem um falso estado online. Idle/Away remoto e Status/stories
não foram implementados. O campo About do perfil não representa stories.

**Settings → Presence consent** exige consentimento explícito por conta e sessão. Só o
contato direto selecionado/visível é inscrito. Há limite de 16 identidades por
época de conexão e uma tentativa por contato a cada cinco minutos. O código novo
não chama o anúncio de presença online da própria conta. O wuzapi pode já fazer
isso ao conectar, e o recebimento pode exigir disponibilidade: a RC9 não altera
silenciosamente essa política nem configurações de privacidade.

Desabilitar o consentimento impede novas inscrições; não existe uma chamada de
cancelamento de inscrição inventada. **O encaminhamento dos eventos pelo backend
é pré-requisito operacional.** Preserve Message e suas assinaturas existentes,
adicionando somente Presence/ChatPresence/Picture realmente suportados pela sua
versão. O pacote não reconfigura uma conexão existente, não chama Connect e não
refaz o pareamento para obter indicadores. Sem eventos, o estado permanece
indisponível. Eventos sem timestamp usam ordem de recebimento, não uma ordem
remota comprovada. Não é criado histórico persistente de presença.

## Fotos, segurança e limites

As fotos vêm de consultas autenticadas ao backend. A implementação usa POST
`/user/avatar`, `/user/info` e, com consentimento, `/user/presence/subscribe`.
Versões incompatíveis geram fallback; a versão atualmente instalada não foi
verificada. JPEG/PNG são aceitos somente em HTTPS no host exato `pps.whatsapp.net`.
Outro host ou formato não abre automaticamente a política de segurança.

Há dois trabalhadores e 16 tarefas em espera no cliente, no máximo 12 contatos
visíveis por consulta e duas tarefas no bridge. A lista de mensagens não carrega
bytes de fotos. As tarefas aguardam leituras/envios visíveis pendentes e não
seguram o mutex de mensagens durante I/O. A resposta da tarefa é autenticada,
de consumo único e expira. Uma consulta upstream travada ainda pode ocupar uma
vaga do Guile; o cliente HTTP herdado não oferece cancelamento forçado seguro.

A resolução DNS validada é fixada na conexão TLS, com validação do certificado
para o hostname original. Não há redirecionamentos, URLs arbitrárias nem tokens
no CDN. A entrada é limitada a 2 MiB, 4096 por dimensão e quatro milhões de pixels;
o FFmpeg prepara PNG de 96/256 pixels com limite de tempo/CPU/memória. Isso reduz
riscos, mas não é sandbox completo de decodificadores.

O cache é apenas em memória: 128 metadados, 32 imagens, 4 MiB de bytes preparados
e um milhão de pixels. Referências do Emacs e bibliotecas podem usar mais memória;
não é limite de RSS. Fotos expiram em 120 segundos e eventos de remoção/troca de
conta invalidam resultados. **Clear profile cache** limpa referências próprias e
consentimento, não promete apagamento seguro da memória. IDs LID e telefone não
são unidos por adivinhação. Falha de foto não significa bloqueio pelo contato.

## Atualizar a instalação existente no GNU Guix

Baixe o pacote e checksum em Downloads; não use sudo:

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc9.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc9.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc9/scripts/update-guix.fish" "$HOME/whatsappel"
```

O comando prepara a candidata isoladamente, executa duas auditorias completas e
só instala após aprovação. Falhas, testes obrigatórios pulados, ferramentas ausentes
ou alterações desconhecidas bloqueiam a substituição. Não há bypass, guix pull,
reconfigure, mudança de perfil, push ou reinício automático. Configuração, sessões,
trabalho não relacionado e PQ independente são preservados. Não copie source/ por
cima da instalação. `--check` só verifica; `--audit-only` só audita.

**A RC9 muda o bridge.** Reinicie o Emacs e o processo Guile realmente utilizado
após instalação aprovada. Mantenha `whatsappel-profiles.scm` ao lado de
`whatsappel.scm`. Em uma VPS, atualize e ative o bridge separadamente; copiar o
cliente na VPS não atualiza o Emacs do notebook. O script de transferência mantém
`root@securityops.co:5119` e verificação da chave SSH, sem mexer no NPM ou wuzapi.
O pacote não adivinha serviço Shepherd/systemd ou container.

```fish
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
and fish scripts/push-four.fish
```

A publicação usa checkout isolado RC9, tokens ocultos e push sem força aos quatro
remotos conhecidos. Nenhuma publicação foi executada nesta preparação. Guarde o
backup e use a linha de rollback exata impressa pela instalação; alterações mais
novas são recusadas. Reinicie cliente e bridge após restaurar.

A suíte inclui testes ERT/Guile, benchmark de seleção com 1.000/10.000 conversas
sintéticas e captura gráfica nativa opcional. A ausência dessas ferramentas não
vira aprovação. Não há screenshot fabricado, ganho de velocidade ponta a ponta,
prova de entrega, teste físico de microfone/mpv ou nova garantia criptográfica.
