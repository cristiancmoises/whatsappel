# RC7: pacote completo, atualização Guix e publicação

O [README em português](../README.pt-BR.md) contém os comandos completos de atualização,
instalação nova, uso e publicação. O [guia técnico em inglês](GUIX-3.2.0-rc7.md) detalha as
transações, remotos e limites. Este documento destaca as diferenças importantes.

A cópia em `source/` é a árvore completa retida, não um espelho verificado do HEAD atual.
Ela serve para inspeção e instalação nova. Na atualização, `payload/` e o manifesto alteram
somente os arquivos gerenciados. Sua configuração, sessões e PQ independente não são
substituídos pela cópia completa. Checksums não equivalem a assinatura digital.

O comando `fish scripts/update-guix.fish ~/whatsappel` usa as ferramentas do seu ambiente,
audita duas vezes e instala somente após sucesso. Não executa `guix pull`, não altera
perfil/geração do sistema e não reinicia serviços. Não execute com sudo. `--check` apenas
verifica; `--audit-only` apenas audita. `--new-install` exige diretório inexistente e usa
publicação atômica sem substituir outro destino criado durante a validação.

Publicação é separada da instalação: usa HEAD commitado, não seus arquivos alterados sem
commit, e executa suas próprias duas auditorias completas. Com `--commit-only`, o resultado
fica em `~/whatsappel-publish-3.2.0-rc7`. Depois, `fish scripts/push-four.fish` envia o mesmo
commit para os quatro remotos com prompts ocultos. `--remote forgejo-co` repete somente
esse destino sem novo commit. Não há push forçado, tags ou releases automáticos. A criação
de repositórios exige `--create-missing --visibility public` ou private explicitamente.

O bridge remoto no IONOS não é atualizado por abrir o Emacs local. O script de deploy
retido usa root@securityops.co:5119 com verificação obrigatória da chave SSH; não reinicia
serviços, não altera NPM/Docker e não troca sessões. `--stage-only` somente transfere/confere.
O destino de instalação precisa corresponder ao diretório real do servidor.

A configuração da conta é escolhida em conjunto: ambiente explícito, senão `.env` privado,
senão init. Token sem URL usa loopback; URL sem token é recusada, sem tomar token de outra
origem. Na primeira instalação nenhum pareamento, segredo ou identidade PQ é criado.

Guarde o comando de reversão e o backup impressos. A reversão verifica hashes e recusa
sobrescrever trabalho posterior. Uma falha de registro de atalho após instalação nova é
informada como tal, deixando o código instalado. Reversão do atalho não apaga essa árvore.
Validação gráfica, microfone, mpv e entrega real continuam necessários. Nenhum push/deploy
ou envio real foi efetuado na preparação deste pacote.
