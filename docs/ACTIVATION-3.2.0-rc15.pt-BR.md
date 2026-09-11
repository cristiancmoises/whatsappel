# RC15 — atualização, ativação verificada e resposta de envio

Este candidato mantém a correção RC14, os identificadores @lid, o rascunho e a
proibição de reenvio automático. Uma falha ao iniciar a atualização do histórico
após o aceite não escapa mais do callback: a mensagem continua marcada como aceita,
com aviso para usar Atualizar, não Enviar novamente. Aceite não confirma entrega.

Baixe o arquivo e SHA-256 para ~/Downloads. No fish, sem sudo:

```fish
function whatsappel_update_rc15
    cd "$HOME/Downloads"; or return 1
    sha256sum -c whatsappel-update-3.2.0-rc15.tar.gz.sha256; or return 1
    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc15.XXXXXX"); or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc15.tar.gz -C "$work"; or return 1
    fish "$work/whatsappel-update-3.2.0-rc15/scripts/update-and-activate.fish" \
        "$HOME/whatsappel" --restart-local
end
whatsappel_update_rc15
```

A opção --restart-local autoriza somente o serviço Shepherd de usuário
whatsappel-bridge já identificado. O programa confirma PID, UID, execução direta
do Guile com o arquivo esperado, conta, porta e socket pertencente ao processo.
Somente HTTP em loopback numérico no Linux permite reinício automático. Serviço
root, VPS, túnel SSH, alias localhost, wrapper desconhecido ou /proc inacessível
exigem ativação manual; o programa não tenta adivinhar nem usa sudo.

As duas auditorias completas continuam obrigatórias. Depois, os hashes de todos
os arquivos gerenciados são conferidos novamente. Alterações da conta/serviço
bloqueiam o reinício. Após um único reinício autorizado, o novo processo e a API
HTTP precisam ser confirmados. Nenhuma sessão, pareamento, callback ou privacidade
é alterada. O init e as abas Home/WhatsAppel/telega são preservados.

No pacote extraído, --check apenas consulta arquivos e endpoints de status;
sem --restart-local, a atualização não reinicia serviço algum. Código 0 significa
arquivos/runtime verificados, 2 significa versão/runtime ainda não confirmados,
1 indica falha, 130 interrupção. Esses resultados não provam entrega no celular.
Uma falha de ativação após instalar não desfaz os arquivos automaticamente: guarde
o backup e o comando exato de rollback exibidos pelo instalador.

O relatório privado separa arquivos divergentes, auditoria, reinício e runtime
verificado. A API de transporte é consultada sem depender apenas do anúncio no
/health. A assinatura de versão é informativa, não atestado criptográfico. Nenhum
token, mensagem, JID ou resposta bruta é incluído no relatório.

Após sucesso, salve os buffers e reinicie completamente o Emacs/daemon. Confira
3.2.0-rc15 em M-x whatsapp-selection-diagnostics. Verifique Check delivery e faça
somente um teste intencional com destinatário que possa confirmar. Nunca reenvie
em lote tentativas antigas de resultado incerto.

Os testes Python incluem processos/HTTP locais reais e arquivos sintéticos.
Fixtures com herd/instalador simulados verificam sequenciamento, não funcionamento
nativo. Emacs, Guile, fish, mpv e Cargo ausentes aqui continuam BLOCKED. Os testes
nativos na sua máquina ainda são necessários. Pale permanece não implementado;
mpv continua uma alternativa explícita em Configurações. Não há ganho de velocidade
medido, nova interface gráfica ou garantia de entrega real nesta iteração.
