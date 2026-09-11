# WhatsAppel 3.2.0-rc8 — validação da seleção de contatos

Preparado em 10/09/2026. **Candidato: validação nativa e real incompleta.** A versão
carregada na sessão do usuário e o backtrace do travamento não foram observados.
A inspeção encontrou trabalho síncrono no RC7; não foi comprovada a causa única
do travamento real nem que todo travamento esteja resolvido.

## Alterações focadas

O campo de composição aparece antes da atualização agendada por um timer normal
após 50 ms. Seleções ultrapassadas, contas diferentes e buffers fechados não podem
executar a abertura atrasada. A seleção na lista muda propriedades sem recriar linhas.

Prévia de texto padrão de 2.048 caracteres, máximo configurável de 8.192; texto
original preservado e leitura explícita em páginas de 8.192 caracteres. Remetentes,
respostas e legendas também têm prévias limitadas. Isso não limita toda a memória
ou todo o processamento de dados do bridge.

A renderização do histórico não inicia decodificação de imagens. Timers normais,
sem forçar redisplay nas consultas da rolagem, processam no máximo uma imagem visível
pronta por rodada. Um decodificador nativo individual ainda pode bloquear.

Mensagens criptografadas não armazenadas em cache exigem **Decrypt** explícito.
O subprocesso pqenv é assíncrono, um por conversa, com limite de dez segundos,
1 MiB de entrada/saída, 64 KiB de stderr e limpeza de temporários privados. Mantém
os argumentos de identidade, remetente e idade; não altera o código criptográfico.
Cancelamento pode ocorrer depois de alteração do estado de replay; não há repetição
automática. Texto aberto fica em memória e o cache é separado por conta/conversa.
Operações legadas explícitas podem continuar síncronas.

## Duas auditorias completas

Cada execução: **337 testes Python encontrados, 313 passaram, 24 ignorados, zero
falhas/erros**. Os 24 dependem de Guile ausente: resultado PARTIAL, não PASS.
Cada controlador terminou com **5 PASS, 1 PARTIAL, 17 BLOCKED; código 1**.
Os 70 hashes de código/build são iguais antes/depois e entre as duas execuções.

Faltam Emacs, Guile, fish, mpv e Cargo neste ambiente. Há **150 testes ERT**, dos quais
26 novos, fornecidos mas não executados. Oito novos contratos estáticos Python
passaram; não substituem execução de Emacs. Testes ERT incluem servidor local lento,
worker Python real, heartbeat, preservação do rascunho, rejeição de callbacks antigos,
textos grandes e ciclo de vida do subprocesso. O subprocesso pqenv fictício testa
somente integração assíncrona, não criptografia.

Testes Python existentes exercitam HTTP/subprocessos reais, limites, ausência de
reenvio automático, arquivos originais, publicação isolada, configuração protegida,
validação do instalador e codificação sintética FFmpeg. Não provam comportamento GUI.
Logs de desenvolvimento interrompidos e uma falha de integridade por edição concorrente
foram preservados, não contabilizados como auditorias finais bem-sucedidas.

## Pacote e limites

O pacote completo usa o RC7 retido mais o delta RC8. Hashes de versões anteriores
explicitamente registradas são mantidos; HEAD remoto e variantes desconhecidas não
foram verificados. O update não sobrescreve configurações, sessões ou código PQ
independentemente mais novo. Testes transacionais de aplicação/rollback não são
execução nativa; veja evidence/package-validation.json. O instalador exige duas
validações completas do candidato exato, sem opção de ignorar falhas.

Reinicie Emacs após update validado e confira M-x whatsapp-selection-diagnostics.
Ele mostra versão, caminho, duração do comando e contagens, sem contatos, URLs,
mensagens ou tokens. Backtraces obtidos manualmente com debug-on-quit podem conter
dados privados e devem ser revisados antes de compartilhar.

Não houve deploy, push, reinício de serviço, nova vinculação ou mensagem real. GUI,
mpv, microfone, entrega, criptografia real e travamento original ainda precisam de
aceitação local. RC7 → RC8 não altera o bridge Guile/wuzapi. Consulte a auditoria
em inglês para IDs e horários exatos e CONTACT-SELECTION-3.2.0-rc8.pt-BR.md para uso.
