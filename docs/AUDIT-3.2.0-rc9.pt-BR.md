# WhatsAppel 3.2.0-rc9 — auditoria executada

**Candidato a lançamento. Validação nativa, gráfica e com conta real pendente.**
As duas auditorias finais retornaram 1: **6 PASS, 1 PARTIAL e 19 BLOCKED** em cada.
Nada foi publicado, implantado ou enviado pela conta do usuário.

## Origem e implementação

Base: pacote RC8 desta conversa, SHA-256
`2d0e34f6eb278b2dd8dd2a187af5397282152fa0bc0cda1e765706eed571b4ef`,
com os 338 checksums internos verificados. O HEAD remoto e o backend instalado
não foram verificados. Alterações desconhecidas são recusadas; a atualização
preserva configuração, sessões e código PQ independente do destino.

A interface nativa ganhou paleta local preto/ciano, espaço reservado para fotos,
cabeçalho com presença observada, painel de contato, configurações e inserção de
emoji. Mantém o layout anterior e a abertura rápida com composição antes da busca.
Não restaura descriptografia síncrona, nem altera o tema global.

O novo módulo Guile separa metadados/trabalhos de perfil do histórico. O worker
Python executa consulta, download controlado e preparação de miniaturas. O módulo
Emacs controla a fila visível, cache em memória, detalhes e consentimento por conta.
Avatares/Info/Subscribe usam os POSTs registrados pelo upstream, sem anunciar
automaticamente a conta como online. Métodos/eventos do backend real ainda exigem
validação local. O código não reconfigura os webhooks: preserve Message e habilite
somente os eventos suportados pelo backend com autorização.

Online/Offline exige evento recente; expira em 60s. Digitando/gravando expira em 8s.
Última visualização oculta/zero/futura continua indisponível. Não inventa Idle/Away,
status de grupo, histórias, bloqueio de contato ou mapeamentos de identidade.
Desabilitar consentimento interrompe novas inscrições, não executa um endpoint
inexistente de cancelamento. O backend pode exigir que a própria conta esteja
disponível para entregar presença; RC9 não muda esse comportamento anterior.

## Segurança e limites

URL de foto: somente HTTPS `pps.whatsapp.net`, sem redirecionar ou encaminhar tokens.
DNS é resolvido e validado uma vez; conexão usa o IP verificado e TLS do hostname
original. Endereços privados/locais/transição são recusados. Outros hosts legítimos
atualmente usam fallback, não uma allowlist ampliada sem verificação.

JPEG/PNG: 2MiB, 4096 por dimensão e 4 milhões de pixels. FFmpeg separado com limites
de CPU/memória/saída/tempo produz PNG 96/256px. Isso reduz riscos, mas não é sandbox
completa de codecs. Fotos preparadas ficam somente em memória: 32 entradas/4MiB/
1 milhão de pixels, TTL120s; metadados128 entradas. Não são limites de RSS do Emacs.
Dois processos/fila16/12 contatos visíveis; leituras/envios normais têm prioridade.
Remoção/revisão/época impede reutilizar fotos atrasadas ou de outra conta.

O Guile mantém dois trabalhos isolados do mutex de mensagens, mas uma chamada
upstream travada pode ocupar uma vaga até terminar. Limites de sinais/processos
não garantem interrupção imediata de todas as chamadas nativas. Permanecem limites
dos comandos antigos, mpv, imagens nativas e criptografia anteriores.

## Resultados efetivos

Cada suíte Python: **387 testes, 345 aprovados, 42 ignorados, zero erros/falhas**.
Os 42 dependem de Guile (24 antigos, 18 novos), portanto o resultado é PARTIAL.
Os **32 testes Python novos** executaram workers/HTTP locais/deadlines/sem reenvio,
validação/remoção de campos e FFmpeg real. Resolução/TLS são fixtures controladas;
não houve acesso real à CDN ou fotos de contatos reais.

**175 ERT fornecidos**, incluindo25 novos, não executados. Incluem servidor lento
de cinco segundos com worker real e verificações de heartbeat/rascunho. Os18
novos testes HTTP Guile também não executaram. Não há captura de tela gráfica:
o script fornecido somente produz PNG real quando executado no Emacs gráfico.

Emacs, Guile, fish, mpv e Cargo estão ausentes neste ambiente; não foram substituídos
por simulações chamadas de aprovação nativa. Os **79 fingerprints** de código são
iguais antes/depois das duas auditorias finais e ao código entregue. Logs completos
ficam em `evidence/final-pass-1` e `evidence/final-pass-2`.

Benchmark real de miniatura: sete amostras, raster sintético simples, inclui iniciar
FFmpeg e exclui rede/Emacs/fotos reais. Mediana 96px **65,459ms**, p95 **71,767ms**;
256px **72,850ms**, p95 **74,979ms**. Não é comparação de velocidade com RC8, nem
prova de abertura de chats em100ms. O benchmark nativo de1.000/10.000 contatos
permanece BLOCKED. Os bytes pequenos refletem a imagem sintética, não fotos reais.

## Histórico, pacote e ativação

Uma falha estrutural de delimitador em fixture ERT foi corrigida. A validação do
ID de trabalho foi corrigida para aceitar o formato real com dois-pontos, com
fixture de processo e teste nativo entre componentes. Mensagens de ativação foram
ajustadas para exigir reinício da ponte RC9. Execuções anteriores sobrepostas a
edições falharam corretamente na integridade e permanecem como desenvolvimento.
Nenhum teste foi removido ou ignorado para esconder falha.

`evidence/package-validation.json` registra aplicação/rollback/hash/patch e
recusas. Transações de baixo nível não equivalem a instalação nativa aprovada.
O instalador mantém duas auditorias obrigatórias; falhas, cobertura parcial ou
runtimes ausentes impedem substituir arquivos. Checksum não é assinatura nem
atestação independente contra um processo que pode editar código e evidências.

**Após instalar com sucesso, reinicie o Emacs e a ponte Guile existente.** RC9 muda
ambos. Não são adivinhados serviços, não altera NPM/Docker/wuzapi nem refaz login.
Backend antigo mostra recurso indisponível. Consulte `PROFILES-3.2.0-rc9.pt-BR.md`.

Ainda pendentes: execução nativa/gráfica, fotos reais, eventos e privacidade do
backend real, áudio/microfone/mpv, entrega ao destinatário e advisories atuais.
Nenhum push, tag, release, deploy, mensagem real ou nova tentativa de CI recusada.
Esta é revisão de implementação com evidência reproduzível, não certificação.

## Verificação final de distribuição

Os **16** testes de pacote/transação passaram. O instalador real, sem mock de
auditoria, executou as duas passagens e recusou a instalação: **130 arquivos
antigos preservados**, zero backups criados. Código nativo continua pendente.
Distribuição: **142 arquivos de fonte**, **109 payloads gerenciados**, **27
arquivos novos/alterados desde RC8**. Consulte os JSONs de evidência.
