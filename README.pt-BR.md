# WhatsAppel 3.2.0-rc1

Cliente WhatsApp nativo do Emacs, com bridge Guile e wuzapi. Esta atualização
mantém a arquitetura existente e adiciona um worker Python para uploads e
conversão explícita de GIF. Não é uma aplicação web e não introduz Node/Baileys.

**Release candidate:** confira os testes executados e as etapas bloqueadas no
[relatório de auditoria](docs/AUDIT-3.2.0-rc1.pt-BR.md). Testes nativos e validação
real precisam passar antes de considerar a atualização pronta para produção.

A interface recebe iniciador no menu de aplicativos, barra lateral de conversas,
controles de imagem/vídeo/GIF/voz/arquivo, preparação do anexo antes do envio,
zoom e salvamento de imagens originais, mpv para áudio/vídeo e histórico inicial
limitado com Show older. Rascunhos mais recentes não são apagados pela conclusão
de um envio anterior. Uploads não são repetidos automaticamente após timeout.

[Guia completo em português](docs/WORKSPACE-3.2.pt-BR.md) ·
[English guide](docs/WORKSPACE-3.2.md) ·
[Especificação de implementação](docs/PROMPT-3.2.0-rc1.md) ·
[Changelog](CHANGELOG.md) · [Licença AGPL-3.0-only](LICENSE)

Arquivos originais são preservados; GIF→MP4 requer ação explícita. O bridge atual
não adiciona a flag de mensagem de voz PTT nem garante GIF em loop no destinatário.
O código/estado do bridge, wuzapi e pqenv não são substituídos. Os scripts de
update conferem hashes, testam uma cópia candidata e criam rollback. O envio
para os quatro remotos usa uma worktree isolada e tokens digitados com entrada
oculta, sem force push ou sobrescrita silenciosa de trabalho não commitado.
