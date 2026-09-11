# RC16 — destinatário, fotos e linhas da interface

Versão candidata baseada no pacote RC15 preservado. Não houve teste de entrega com
sua conta real. Os relatórios antigos não comprovam qual versão está instalada agora.

O envio normal de texto usa /send/verified e exige confirmação do identificador exato
da conversa. @lid não vira telefone; grupos mantêm @g.us. Uma ponte antiga produz um
erro de ativação, sem tentar novamente pelo endpoint antigo. ID aceito não significa
mensagem entregue. Rascunhos são preservados em resultados incertos; não há reenvio
automático. Respostas de erro exibem somente categorias locais, sem texto do provedor.

Mensagens históricas com sender_jid="me" e sem Info permanecem próprias. Uma indicação
explícita IsFromMe=false prevalece. A consulta About usa JID telefônico completo e
preserva LID, sem adivinhar relações entre os dois identificadores.

A foto mostra uma categoria de falha em Contact info (C-c i): provedor, política de
CDN, rede, FFmpeg ou decodificação. Retry photo tenta apenas aquele contato, preservando
consentimento de presença e outras fotos. Uma foto oculta não significa bloqueio.
HTTPS, endereços permitidos e limites não são enfraquecidos.

As linhas decorativas são desativadas diretamente nas faces de seleção e mouse.
A sobreposição global de hl-line é removida somente quando pertence ao buffer atual
do WhatsAppel. Outros buffers, sobreposições, tema global e init não são alterados.

Use o comando fish do README após baixar o arquivo e checksum em ~/Downloads, sem sudo.
O instalador verifica duas auditorias completas, substitui somente arquivos conhecidos
e reinicia apenas a ponte local verificada após o sucesso. Não reinicie depois de uma
falha de auditoria. Reinicie também o Emacs/daemon após instalar e confirme
3.2.0-rc16 em M-x whatsapp-selection-diagnostics.

A ponte e o cliente precisam estar atualizados juntos. Não copie source/ por cima da
instalação. Guarde o backup e o comando de rollback impresso. Não há alteração de
sessões, .env, perfil Guix, init, publicação Git ou envio real durante a preparação.
A ativação não comprova conectividade do callback ou entrega no telefone.

Pale continua incompleto; esta correção não implementa um novo reprodutor. Não há
promessa de desempenho medida nem validação gráfica quando Emacs não está disponível.
Consulte AUDIT-3.2.0-rc16.md para resultados executados e bloqueios. Teste uma mensagem
nova com um destinatário que possa confirmar o recebimento, sem repetir tentativas
anteriores incertas. Use Photo: para identificar a falha real das imagens.
