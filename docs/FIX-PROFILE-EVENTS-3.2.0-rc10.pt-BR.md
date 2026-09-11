# RC10: correção da validação de eventos de perfil

Os dois arquivos de diagnóstico enviados são idênticos. As duas auditorias da RC9
falharam na mesma asserção: um evento online com identidade de grupo retornou 200
em vez de 400. Os 79 hashes de código coincidem com o pacote RC9 retido.

A ponte verificava primeiro se havia um registro em cache, retornando ignorado
antes de validar os campos. A RC10 normaliza e valida o evento antes dessa consulta.
Assim, eventos malformados são recusados independentemente do cache; eventos válidos
de contatos não solicitados continuam ignorados sem criar registros.

Fotos de grupos, presença observada, consentimento, mensagens, contagem de não
lidas e autenticação são preservados. O teste original não foi removido. Foram
adicionados 12 métodos de teste nativos e 10 testes Python de diagnóstico.
Consulte a auditoria para distinguir execução de bloqueio por runtime ausente.

## Atualizar

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc10.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc10.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc10/scripts/update-guix.fish" \
    "$HOME/whatsappel"
```

A RC9 não precisa estar instalada. Não use sudo. O comando verifica compatibilidade,
monta um candidato isolado e executa duas auditorias completas antes de substituir
arquivos gerenciados. Não altera perfis Guix, sessões, configuração, PQ independente,
serviços, webhook ou Git. Alterações desconhecidas são recusadas.

Após sucesso, reinicie o Emacs e o processo real da ponte Guile, pois a correção
altera `whatsappel-profiles.scm`. Copiar arquivos não ativa o código no processo em
execução. No IONOS, a origem e a ativação da ponte são etapas separadas, sem adivinhar
serviços. O host permanece root@securityops.co, porta SSH 5119, com verificação da
chave do servidor. Guarde o backup e o comando de rollback exibidos.

## Ler os relatórios antigos sem repetir testes

```fish
python3 scripts/audit-workspace.py --summarize \
    "$HOME/whatsappel-audit-20260910T153309932741Z"
```

Esse caminho é o relatório RC9 enviado; use o novo caminho impresso para outras
auditorias. O resumo mostra apenas identificadores limitados, não valores de
asserção ou backtraces. Nenhum teste é executado pelo resumo.

Sem nova interface, melhoria de velocidade medida, integração Pale, criptografia,
envio real de mensagens ou push nesta correção. O mpv é mantido. Validação nativa
no Guix e aceitação na sessão real continuam necessárias.
