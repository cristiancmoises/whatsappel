# RC17 — preservar rascunho e resposta ao receber uma resposta inválida

O teste informado nas duas execuções do RC16 é
`whatsapp-workspace-send-failure-retains-draft-and-reply`. O relatório de ativação
informa `installed: false` e `restart_attempted: false`: o pacote não foi instalado
e o serviço não foi reiniciado pelo atualizador. Os arquivos ausentes/alterados
são diferenças entre a instalação e o candidato, não prova de corrupção.

O teste original passa `(200 . :invalid-json)` ao callback. O código rejeita a
confirmação, mas tentava usar `assoc` no símbolo `:invalid-json` ao montar o erro.
O RC17 verifica primeiro se o corpo é uma lista própria. Caso não seja, usa o aviso
constante de envio não confirmado, mantendo rascunho, resposta citada e edições
novas. Não aceita JSON inválido, não tenta enviar novamente e não expõe erros
brutos do servidor. O teste original permanece idêntico, sem remoção de asserções.

O único ajuste de comportamento é essa verificação de tipo. Foram adicionados
10 testes ERT sobre callbacks síncronos/adiados, campos inesperados, alterações de
conta, duplicatas, rascunho/resposta/undo, fechamento de buffer e sucesso normal.
Os relatórios distinguem execução real, testes bloqueados e validação parcial;
checagem estrutural em Python não substitui Emacs ou Guile.

Baixe o arquivo completo e o SHA-256 para ~/Downloads. Siga a função fish do guia
em inglês (SEND-FAILURE-3.2.0-rc17.md): ela testa primeiro a regressão específica,
depois executa as duas auditorias completas, instala apenas após sucesso e só
então pode reiniciar o serviço local verificado. Não use sudo, guix pull, cópia
manual de source/, nem reinicie separadamente após uma falha.

Configuração, init, sessões, chaves e alterações independentes em pqenv são
preservadas. O RC16 não precisa ser instalado antes; hashes antigos reconhecidos
continuam aceitos. Alterações desconhecidas são recusadas. Após sucesso, salve
seus buffers e reinicie completamente o Emacs/daemon; confirme 3.2.0-rc17 em
M-x whatsapp-selection-diagnostics. Mantenha o backup e o comando exato de rollback.

Esta correção trata a apresentação de falhas, não comprova entrega no celular,
fotos reais, funcionamento do Pale ou ganho de desempenho. Não reenvie tentativas
incertas em massa. Nenhuma conta, mensagem, callback, serviço real ou remoto Git
foi alterado durante a preparação.
