# WhatsAppel 3.2.0-rc10 — auditoria da correção

**Versão candidata; validação nativa e aceitação na conta real não foram concluídas.**
Nenhum push, deploy, alteração da conta ou reinício de serviços foi efetuado.

## Diagnóstico exato

Os dois arquivos enviados são idênticos. Os 79 hashes de código dos relatórios
coincidem com a RC9 retida. Cada auditoria do usuário teve 24 PASS e 2 FAIL. A suíte
Python teve 386 sucessos e uma falha em 387 testes; a suíte de perfis teve 17
sucessos e a mesma falha em 18. A asserção esperava HTTP 400 para presença online de
um grupo, mas recebeu 200. Esses resultados são da RC9, não da RC10.

A ponte retornava ignorado para identidades fora do cache antes de validar os
campos. A correção valida e normaliza antes dessa consulta. Eventos válidos de
contatos não solicitados continuam ignorados sem armazenamento. Eventos inválidos
são recusados independentemente do cache. Fotos de grupos continuam permitidas;
a correção não inventa presença de grupos nem altera mensagens/não lidas.

O método de teste originalmente falho permanece intacto. Foram adicionados 12
métodos nativos para presença, atividade, fotos, timestamps, cache e ausência de
mutações em mensagens. O resumo agora mostra identificadores Python limitados, sem
valores de asserção; dez novos testes Python dessa funcionalidade passaram.

## Execução local, duas vezes

- Python: **409 descobertos, 355 aprovados, 54 ignorados, zero falhas/erros**.
- Cada auditoria: **6 PASS, 1 PARTIAL, 19 BLOCKED; código de saída 1**.
- **80 hashes de código** iguais antes/depois de ambas as execuções.
- **175 testes ERT** mantidos, não executados aqui.
- Guile, Emacs, fish, mpv e Cargo ausentes; tentativas de obter dependências
  falharam na resolução DNS. Nenhum runtime falso foi usado.

Os 54 testes ignorados requerem Guile (24 antigos + 30 de perfis). Os novos testes
nativos não foram executados. Os dez testes novos executados verificam diagnóstico,
não a implementação Scheme. Suítes existentes também exercitam HTTP local, workers,
FFmpeg e transações Git isoladas. Isso não comprova a sessão real do WhatsApp.

Consulte os relatórios completos em `evidence/pass-1` e `evidence/pass-2`, o
`diagnosis.json` sanitizado e `package-validation.json`. Testes de cópia/rollback
não substituem testes nativos. Relatórios privados do usuário não são republicados.

## Instalação e limites

O pacote cumulativo mantém hashes conhecidos anteriores e recusa edições
incompatíveis. A RC9 não precisa estar instalada. A atualização normal preserva
configuração, sessões e PQ independente; o gate de duas auditorias completas não
foi desativado. Falhas, cobertura parcial e runtimes ausentes impedem substituição.

Após sucesso, reinicie o Emacs e o processo real da ponte Guile. A correção altera
o módulo de perfis carregado pela ponte. Não há novo ganho de desempenho medido,
integração Pale, alteração de criptografia ou anúncio automático de disponibilidade.
Fotos reais, eventos do provedor, interface gráfica, microfone/vídeo e entrega de
mensagens continuam sujeitos à aceitação na máquina real. Auditoria de desenvolvimento
não é certificação de segurança nem garantia de ausência de erros.
