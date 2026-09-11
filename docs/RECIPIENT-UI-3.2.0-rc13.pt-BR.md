# RC13 — destinatário correto, envio visível e navegação sem linhas decorativas

**Candidato baseado no RC11 completo.** O RC12 era trabalho parcial de revisão e
diagnóstico; não é uma versão instalada exigida. O envio real para o celular do
destinatário ainda precisa de validação na instalação do usuário.

## Correções

O cliente antigo preservava grupos, mas removia @lid dos demais identificadores.
Isso transforma uma identidade LID opaca em dígitos interpretados como telefone e
pode armazenar a mensagem em outra conversa. RC13 preserva @lid, mantém grupos e
normaliza apenas os sufixos telefônicos conhecidos. O destino do envio de texto é
recalculado pela identidade da conversa. Nenhuma associação LID/telefone é inventada;
nenhuma tentativa antiga é reenviada ou migrada automaticamente.

O único teste ERT que falhou no relatório enviado usava a assinatura antiga do
worker e esperava /send pelo transporte URL legado. O identificador do teste foi
mantido e o contrato atual foi testado: GETs e envio explícito pelo worker protegido,
outro POST legado pelo caminho existente. A validação do envio não foi enfraquecida.
Os 462 testes Python passaram no relatório do usuário; isso não equivale à validação
desta versão RC13.

## Envio visível sem confundir aceitação com entrega

Um envio normal de texto mostra imediatamente uma nota local: Sending, Accepted
awaiting history/receipt ou Unconfirmed. São estados locais, não comprovantes de
entrega. O texto mais recente do rascunho é preservado. A nota aceita desaparece
apenas quando o mesmo ID do provedor aparece como mensagem própria na conversa.
Não se deduplica por texto. Delivered/Read dependem dos recibos autenticados existentes.

As notas usam uma única sobreposição pertencente ao aplicativo, sem alterar os
caracteres do histórico, marcadores ou posições de desfazer. Limites: 16 notas e
256 KiB de texto; ficam somente na memória enquanto o buffer da conversa existe.
Uma repetição idêntica de envio não confirmado é bloqueada até revisão e descarte
explícito em Clear local send notes. Essa ação não reenvia nem apaga mensagens remotas.
Os novos estados locais são para texto normal; mídia/PQ mantêm os fluxos anteriores.

A opção whatsapp-profile-clean-lines vem ativada. Remove sublinhados, linhas acima,
caixas e guias de editor dos buffers WhatsAppel, mantendo a seleção por fundo.
Não altera o tema global nem as abas Home/WhatsAppel/telega. A barra de ações passa
para a linha seguinte conforme a largura. Artefatos externos do driver não são
considerados resolvidos sem observação nativa.

## Atualização GNU Guix

Baixe o arquivo e seu SHA-256. Use o comando completo da resposta/guia inglês para
extrair em pasta nova e executar scripts/update-guix.fish ~/whatsappel. Não use sudo,
não copie source/ por cima da instalação e não desative testes. O instalador executa
duas auditorias completas, preserva .env, sessões, alterações independentes de PQ e
recusa arquivos desconhecidos. Não é necessário rodar duas auditorias extras antes.

Somente depois de instalar com sucesso, reinicie o serviço de usuário já identificado:

```fish
herd --log-history=0 status whatsappel-bridge
and herd restart whatsappel-bridge
and herd --log-history=0 status whatsappel-bridge
```

Salve o trabalho e reinicie também o Emacs, incluindo seu daemon quando existir.
M-x whatsapp-selection-diagnostics deve mostrar 3.2.0-rc13. Use Check delivery para
conferir o transporte. Conectado não prova callback alcançável nem entrega no celular.
Faça apenas uma nova mensagem de teste intencional com um destinatário que concorde
em confirmar; não reenvie tentativas antigas automaticamente. Guarde o backup e o
comando de reversão impresso. Nenhum serviço foi reiniciado durante a preparação.

## Limites

Os testes nativos precisam rodar na máquina GNU Guix. Consulte AUDIT-3.2.0-rc13.md
para os resultados reais, sem tratar testes pulados como aprovados. A reprodução real
via Pale continua incompleta; este reparo não implementa esse backend. Configurações
de callback, arquivos expirados, fotos restritas e presença privada não são corrigidos
apenas preservando o identificador. Não houve envio real, push, deploy, troca de chaves,
reconexão, pareamento ou alteração do init. Guias anteriores ficam como histórico.
