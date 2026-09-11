# WhatsAppel 3.2.0-rc6 — auditoria executada

**Candidato de lançamento; validação nativa/real ainda incompleta.** Os dois novos
passes completos retornaram 1: 5 PASS, 1 PARTIAL e 15 BLOCKED por passe. Emacs,
Guile, fish, mpv e Cargo estão ausentes neste ambiente. Tentativas de obter os
pacotes/referências falharam; isso não foi transformado em aprovação simulada.

## Diagnóstico exato dos arquivos enviados

Os 62 hashes dos dois passes RC5 coincidem com o código retido reconstruído.
O usuário executou 19 verificações aprovadas e duas com falha por passe: ERT com
107/108 aprovados e Guile com 77 aprovações e uma falha. Esses números são da RC5,
não da RC6.

O ERT procurava o texto antigo `Show older`, apesar do botão real `Load older`.
O teste passa agora a localizar o comando, ativar o botão real, verificar o
histórico expandido e preservar o rascunho. O teste Guile usava `test-error` com
dois argumentos, interpretando o nome como especificação do erro; foi corrigido
para `(test-error "nome" #t expressão)`. Foram adicionadas asserções de limites,
tipos inválidos, valores válidos/default e classe de exceção. O ambiente do teste
é restaurado. Nenhum limite ou validação da ponte foi desativado.

## Melhorias delimitadas

O polling percorre janelas visíveis em vez de todos os buffers; elimina duplicatas,
ignora frames ocultos/minimizados e buffers fechando, preserva backoff e isola
exceções síncronas por buffer. Não foi medido ganho percentual da interface.

O launcher lê `.env` por um único descritor limitado, sem seguir links nem bloquear
em FIFO. Exige arquivo regular privado do usuário, UTF-8 válido e uma atribuição
por variável reconhecida. Recusa substituição de shell e caracteres de controle.
A ausência do arquivo continua permitindo configuração no init do Emacs. Testes
comparativos reais com arquivos sintéticos mostram que RC5 aceitava permissão
0644 e atribuições duplicadas; RC6 recusa ambos e mantém o caso válido 0600.
Não é uma sandbox contra processos hostis do mesmo usuário.

As falhas nativas exibem nome de teste/linha, sem valores de asserções/backtraces.
O modo `--summarize` apenas lê relatórios existentes; não executa testes, limita
arquivos, recusa links e ignora caminhos de log fornecidos pelo relatório.
O resumo preserva falhas, mas não constitui atestação independente.

## Resultados novos

Cada passe Python descobriu 284 testes: **260 aprovados, 24 ignorados, zero erros
ou falhas**. Os 24 ignorados exigem Guile e tornam a cobertura PARTIAL. Os 48 novos
testes Python passaram nos dois passes completos e também em uma execução focada.
Há 118 testes ERT fornecidos (10 novos), ainda não executados aqui. A suíte Guile
adiciona 13 asserções. As verificações estruturais não substituem os runtimes.

Ambos os passes mantêm os mesmos 64 hashes de código antes/depois. As verificações
estruturais, benchmarks herdados, FFmpeg e integridade passaram. Emacs, Guile,
fish, mpv e Rust permaneceram bloqueados. O histórico de um erro intermediário
com descritor de diretório foi preservado; o código foi corrigido e o teste
mantido e aprovado. Logs brutos do usuário não foram incluídos na distribuição.

Consulte `evidence/package-validation.json` para aplicação cumulativa, reversão,
recusa de mudanças desconhecidas e integridade. Fixtures transacionais de baixo
nível não comprovam execução nativa. O instalador continua exigindo dois passes
completos vinculados ao candidato exato antes de escrever os arquivos instalados.
A documentação foi finalizada após as auditorias, sem alterar o código auditado.
Checksums não são assinaturas. HEAD remoto e variantes não registradas não foram
presumidos compatíveis.

Não houve deploy/push, mensagens reais, mudanças de serviço, NPM/Docker, nova
branch/tag/release nem nova tentativa da escrita de CI recusada. Ponte, wuzapi e
PQ não mudam entre RC5 e RC6. Interface gráfica, microfone, janelas mpv, entrega
real e consulta atual de vulnerabilidades continuam pendentes. As limitações
anteriores de voz/GIF/PQ e operações síncronas antigas permanecem.

Use `RECOVERY-3.2.0-rc6.pt-BR.md`: um único comando de instalação executa os dois
passes completos antes de instalar. Não é necessário repetir antes outra dupla.
Guarde o backup e o comando exato de rollback até concluir a aceitação real.
