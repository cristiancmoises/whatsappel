# RC14: aviso de envio após troca de conta

O RC13 não foi instalado: a auditoria recusou a substituição. O restart posterior
carregou os arquivos antigos, não o candidato temporário.

O teste `wa-rc3-late-send-after-account-change-retains-draft` verifica tanto o
rascunho quanto `whatsapp--last-error`. O ramo de resposta tardia do RC13 preservava
o rascunho e a nota de resultado incerto, mas não definia esse aviso. O RC14 restaura
o aviso no código de produção. O teste original permanece byte a byte inalterado.
A análise é do código e do nome do teste informado; não foi fornecido o traceback
ERT completo deste caso, nem houve reprodução nativa aqui.

Seis novos testes ERT cobrem troca de token/URL, preservação do texto/cursor/marcador,
resposta citada e undo, ausência de segredos no erro, callback duplicado, isolamento
do buffer e aceitação normal. Não há reenvio automático nem mudança no destino ou
na validação do ID do provedor. O sufixo LID e a remoção de linhas do RC13 permanecem.

Use a função completa do [guia em inglês](LATE-SEND-3.2.0-rc14.md). Ela verifica o
arquivo baixado, extrai em uma nova pasta, executa as duas auditorias, instala,
verifica os arquivos instalados e só então reinicia o serviço local identificado.
Se a auditoria falhar, não haverá restart. Não use sudo e não sobrescreva source/.

Após sucesso, salve o trabalho e reinicie completamente o Emacs (incluindo daemon).
Confirme 3.2.0-rc14 em `M-x whatsapp-selection-diagnostics`. Configuração, abas,
sessões, PQ independente e backups são preservados. Use o rollback exato impresso
pelo instalador e mantenha o backup até verificar o comportamento real.

Pale e entrega real continuam sem comprovação nesta correção. Não houve envio real,
push, reconfiguração Guix ou restart de serviço do usuário durante a preparação.
