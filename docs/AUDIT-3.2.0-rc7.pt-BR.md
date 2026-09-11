# WhatsAppel 3.2.0-rc7 — auditoria executada

Preparado em 10 de setembro de 2026. **Versão candidata; validação nativa e real incompleta.**
Ambas as auditorias completas retornaram 1: 5 PASS, 1 PARTIAL e 17 BLOCKED por passagem.
O resultado nativo anterior do usuário era RC5, não RC7. As correções RC6 da expansão de
histórico e do uso de SRFI-64 são mantidas; não foram removidos testes nem enfraquecidos limites.

## Base e correções

Base: árvore completa 3.1 retida, com sobreposição do payload cumulativo RC6 verificado.
O HEAD atual dos remotos não foi confirmado. `source/` inclui a árvore retida completa com
RC7, mas uma atualização normal aplica apenas arquivos gerenciados. Configuração, sessões
e PQ atualizado independentemente vêm da instalação real e não são sobrescritos.

Uma comparação executou as funções Python de lançamento RC6/RC7 com valores sintéticos e
`execve` simulado: RC6 combinava token de ambiente com URL de outro arquivo; RC7 não combina.
O ponto de entrada Lisp também deixa de tomar o token do init para uma URL externa. São
fornecidos seis novos testes ERT, ainda não executados aqui. Token sem URL usa loopback;
URL sem o próprio token é recusada. A configuração privada continua sem execução de shell.

O novo comando fish atualiza a instalação existente com duas auditorias completas. Não
executa guix pull, não muda perfil/geração, não instala ferramentas, não reinicia serviço
e não altera pareamento. A instalação nova é explícita, exige diretório inexistente e usa
renameat2 sem substituição após a validação. Testes reais exercitaram a operação atômica.
Testes transacionais simulam a etapa nativa apenas para verificar ordem e preservação.

A publicação verifica bytes de HEAD antes de criar worktree e recusa diretórios dentro de
outro repositório. Audita o candidato em escopo completo, faz commit somente dos arquivos
gerenciados e permite repetir o push sem novo commit. Os READMEs foram reescritos em inglês
e português; o texto histórico foi arquivado, não misturado ao guia atual.

## Resultados

| Verificação | Resultado em cada passagem |
|---|---|
| Python | 329 descobertos; 305 passaram; 24 ignorados; nenhuma falha/erro |
| Novos testes RC7 Python | 45 passaram, também em execução direcionada separada |
| Estrutura Lisp | PASS, sem equivalência a compilação/execução nativa |
| Benchmarks JSON/envelope e FFmpeg | PASS, sem medição de ganho global do RC7 |
| Integridade | 68 hashes de código/build idênticos antes/depois das duas passagens |
| ERT | 124 casos fornecidos; Emacs indisponível |
| Guile/HTTP | Bloqueados por Guile ausente; os 24 skips Python dependem dele |
| fish/mpv/Cargo | Verificações nativas bloqueadas por ferramentas ausentes |

Guix também não está instalado no ambiente de preparação. Não foi verificada a resolução
de pacotes dos seus canais. Uma tentativa de acesso ao endpoint Debian falhou por DNS.
Uma execução inicial de desenvolvimento foi interrompida pelo limite curto da ferramenta;
o log parcial foi mantido e não foi contado como auditoria completa aprovada.

Onze verificações de pacote/transação passaram: aplicar/reverter versões retidas, preservar
configuração/sessão/PQ, rejeitar alteração desconhecida, aplicar/reverter o patch RC6,
conferir a fonte completa contra o payload, verificar instalação nova sem criar destino e
recusar adulteração da fonte. Isso não representa execução das suítes nativas.

A invocação separada do instalador real está em `evidence/native-install-refusal.json`: duas
auditorias completas no fluxo padrão de atualização, sem simular a barreira nativa. O arquivo
registra código de saída, contagem exata de arquivos intactos e ausência de backup de instalação.
A invocação retornou 1, manteve os 113 arquivos existentes intactos e não criou backup de instalação.
O relatório externo final confere archive, fonte completa, payload e fingerprints auditados.

Não houve acesso à VPS, push, tag, release, mensagem real, reconfiguração, novo pareamento
ou tentativa de repetir a escrita de CI anteriormente recusada. Interface gráfica, microfone,
mpv, entrega real e avisos atuais de vulnerabilidades continuam pendentes. Não foi medido
ganho de velocidade global. RC6 → RC7 não altera bridge/wuzapi/PQ. Checksums não são assinatura
nem atestado independente. Execute as duas auditorias nativas na sua instalação e mantenha
backup até validar o uso real. Consulte README.pt-BR.md e GUIX-3.2.0-rc7.pt-BR.md.
