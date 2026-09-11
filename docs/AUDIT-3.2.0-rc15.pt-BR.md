# RC15 — auditoria executada e limites

Candidato, não validação nativa ou de entrega real. As duas auditorias finais
retornaram 1: 6 PASS, 1 PARTIAL e 21 BLOCKED. Em cada execução: 521 testes Python,
444 passaram, 77 ignorados por falta do Guile, zero falhas/erros. Os 55 novos testes
Python também passaram em execução isolada. Há 220 testes ERT, quatro novos, não
executados porque Emacs está ausente. Os 91 hashes de código coincidem antes/depois
das duas auditorias e com a fonte distribuída.

A correção RC14 e seu arquivo de regressão original foram preservados. RC15 protege
a atualização do histórico após aceite, sem alterar destinatário, limite, rascunho
novo, isolamento de conta ou política contra reenvio automático. A evidência é de
inspeção de código; não reproduzimos a entrega no celular ou a callback em Emacs.

O novo fluxo verifica arquivos instalados e, apenas com --restart-local, o serviço
Shepherd de usuário, UID, fonte Guile, conta/porta, tempo de início e socket. Falha
na auditoria bloqueia ativação. Novo processo e versão/API devem ser observados
após reinício. Runtime confirmado não comprova registro/rede/entrega real.

Os novos testes executam arquivos, comandos limitados, HTTP local, CLI e inode de
socket real do processo de teste. Metadados /proc de Guile são sintéticos. Resultados
de herd/instalador são simulados somente nos testes de sequenciamento; não são
execução nativa nem recibos reais. Os testes originais não foram enfraquecidos.

A primeira execução teve erros de fixture pela diferença entre UID simulado e
proprietário do .env temporário. A propriedade da fixture foi ajustada. Sete testes
duplicados por herança continuam na classe própria. Os logs iniciais foram mantidos.
APT não obteve ferramentas por falha de DNS. Verificações nativas continuam
bloqueadas, não substituídas por comparação estrutural de Lisp.

A distribuição inclui verificação do pacote/patch/rollback separada das auditorias.
A instalação no Guix ainda exige duas auditorias nativas completas. Não houve push,
serviço do usuário reiniciado, mensagem enviada, pareamento, edição do init ou
alteração de callback nesta preparação. Pale permanece incompleto; não há promessa
de ganho de velocidade ou interface validada graficamente. Guarde os backups.

## Verificação final do pacote

Os 14 testes de empacotamento passaram: integridade, equivalência de código/payload,
atualização e restauração exatas desde RC10/RC11/RC13/RC14, recusa de alterações
não reconhecidas, links e payload corrompido, proteção de alterações posteriores,
aplicação/reversão do patch e CLI em modo de verificação. As transações de arquivos
não substituem testes nativos.

Uma execução real de finish-update.py como UID 1000, sem reinício e sem simular o
validador, rodou as duas auditorias completas em uma instalação descartável RC14.
Ela recusou a instalação, preservou **174 arquivos existentes** e produziu **zero
backups de instalação e nenhuma tentativa de reinício**. Configuração, dados de
sessão sintéticos, bytecode e fonte PQ independente permaneceram intactos.

Uma primeira fixture tinha evidências privadas pertencentes a root e foi recusada
antes da auditoria; a propriedade da cópia descartável foi corrigida. Outra fixture
incluía o diretório .git no comparativo de fontes; isso foi corrigido e os 14 testes
foram repetidos. O código da aplicação e os critérios nativos não foram relaxados.
