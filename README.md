# 🚀 Nano Pilot

Um plugin minimalista para Neovim que traz a experiência do Cursor IDE com integração completa da API do Claude, aplicação automática de código e interface conversacional intuitiva.

## ✨ Características

- 💬 **Chat integrado**: Interface flutuante elegante para conversas com Claude
- 🔧 **Aplicação automática de código**: Aplique código diretamente nos seus arquivos
- 📁 **Contexto inteligente**: Inclua múltiplos arquivos para contexto completo
- 🎯 **Preview com diff**: Visualize mudanças antes de aplicar
- ⚡ **Navegação entre blocos**: Navegue facilmente entre múltiplos blocos de código
- 🎨 **Interface moderna**: Design limpo com bordas arredondadas e syntax highlighting
- 📚 **Histórico persistente**: Mantém contexto completo da conversa
- ⌨️ **Atalhos intuitivos**: Teclas de atalho bem pensadas para fluxo eficiente

## 📦 Instalação

### 🔑 Primeiro: Configure sua API Key

```bash
# Adicione ao seu ~/.bashrc, ~/.zshrc ou equivalente
export ANTHROPIC_API_KEY="sua-chave-anthropic-aqui"
```


```bash
# Adicione no seu profile do power shell (Windows)
$env:ANTHROPIC_API_KEY="sua-chave-anthropic-aqui"
```

### Lazy.nvim

```lua
{
  "estevaofon/nano-pilot",
  config = function()
    require("nano-pilot").setup({
      -- A API key será lida automaticamente da variável de ambiente
    })
  end,
  dependencies = {
    "nvim-telescope/telescope.nvim", -- opcional, para seleção de arquivos
  },
}
```

### Packer

```lua
use {
  "seu-usuario/nano-pilot",
  config = function()
    require("nano-pilot").setup({
      -- A API key será lida automaticamente da variável de ambiente
    })
  end
}
```

### Vim-Plug

```vim
Plug 'seu-usuario/nano-pilot'

lua << EOF
require("nano-pilot").setup({
  -- A API key será lida automaticamente da variável de ambiente
})
EOF
```

## 🔧 Configuração

### Configuração Básica

```lua
require("nano-pilot").setup({
  -- A API key será lida automaticamente da variável de ambiente ANTHROPIC_API_KEY
  -- Nenhuma configuração adicional é necessária para uso básico
})
```

### Configuração Avançada

```lua
require("nano-pilot").setup({
  -- API Configuration
  -- api_key é lida automaticamente de ANTHROPIC_API_KEY
  -- Se necessário, pode ser sobrescrita:
  -- api_key = "sua-chave-personalizada",
  
  model = "claude-3-5-sonnet-20241022",
  max_tokens = 8192,
  temperature = 0.7,
  history_limit = 20, -- número de mensagens para manter no contexto
  
  -- UI Configuration
  chat_window = {
    width = 100,
    height = 35,
    border = "rounded", -- none, single, double, rounded, solid, shadow
  },
  code_window = {
    width = 80,
    height = 20,
    border = "rounded",
  },
  
  -- Keymaps (dentro das janelas do plugin)
  keymaps = {
    apply_code = "<C-a>",
    copy_code = "<C-c>",
    next_code_block = "<C-n>",
    prev_code_block = "<C-p>",
    toggle_diff = "<C-d>",
  },
})
```

## ⌨️ Atalhos

### Atalhos Globais (padrão)

| Atalho | Modo | Ação |
|--------|------|------|
| `<leader>cc` | Normal | Abrir/fechar chat |
| `<leader>cp` | Normal | Prompt rápido |
| `<leader>cp` | Visual | Prompt com seleção |
| `<leader>cf` | Normal | Selecionar arquivos para contexto |
| `<leader>cl` | Normal | Listar arquivos selecionados |
| `<leader>ct` | Normal | Toggle arquivo atual no contexto |
| `<leader>ca` | Normal | Aplicar último código |
| `<leader>cr` | Normal | Substituir arquivo inteiro |
| `<leader>cd` | Normal | Aplicar com preview diff |
| `<leader>ci` | Normal | Mostrar informações |
| `<leader>ch` | Normal | Mostrar ajuda |

### Atalhos no Chat

| Tecla | Ação |
|-------|------|
| `i`, `Enter` | Novo prompt |
| `q`, `Esc` | Fechar chat |
| `c` | Limpar chat e histórico |
| `h` | Mostrar ajuda |
| `Ctrl+n` | Próximo bloco de código |
| `Ctrl+p` | Bloco anterior |

### Atalhos no Preview de Código

| Tecla | Ação |
|-------|------|
| `Ctrl+a` | Aplicar código no arquivo |
| `Ctrl+c` | Copiar código |
| `q`, `Esc` | Fechar preview |

### Atalhos no Input

| Tecla | Ação |
|-------|------|
| `Enter` | Enviar prompt |
| `Ctrl+Enter` | Nova linha |
| `Esc` | Cancelar |

## 🎯 Comandos

| Comando | Descrição |
|---------|-----------|
| `:SimpleCursorChat` | Abrir/fechar chat |
| `:SimpleCursorPrompt` | Prompt rápido |
| `:SimpleCursorSelectFiles` | Selecionar arquivos |
| `:SimpleCursorListFiles` | Listar arquivos selecionados |
| `:SimpleCursorToggleCurrentFile` | Toggle arquivo atual |
| `:SimpleCursorApplyCode` | Aplicar último código |
| `:SimpleCursorReplaceFile` | Substituir arquivo inteiro |
| `:SimpleCursorDiffApply` | Aplicar com diff |
| `:SimpleCursorClearFiles` | Limpar seleção de arquivos |
| `:SimpleCursorClearChat` | Limpar chat |
| `:SimpleCursorInfo` | Mostrar informações |
| `:SimpleCursorHelp` | Mostrar ajuda |

## 🚀 Fluxo de Trabalho

### 1. Configuração Inicial
```bash
# Obtenha sua API key em: https://console.anthropic.com/
# Adicione ao seu shell profile (~/.bashrc, ~/.zshrc, etc.)
export ANTHROPIC_API_KEY="sua-chave-aqui"

# Recarregue o shell ou reinicie o terminal
source ~/.bashrc  # ou ~/.zshrc
```

### 2. Uso Básico
1. Abra o Neovim em seu projeto
2. Pressione `<leader>cc` para abrir o chat
3. Digite seu prompt e pressione Enter
4. O Claude responderá com código e explicações

### 3. Trabalhando com Código
1. Quando Claude retornar código, use `Ctrl+n`/`Ctrl+p` para navegar entre blocos
2. Pressione `Ctrl+a` no preview para aplicar o código
3. Escolha como aplicar: substituir arquivo, inserir no cursor, ou anexar

### 4. Contexto de Arquivos
1. Use `<leader>cf` para selecionar arquivos importantes
2. Use `<leader>ct` para incluir o arquivo atual
3. O Claude terá acesso a todos os arquivos selecionados para contexto

### 5. Aplicação Rápida
- `<leader>cr`: Substitui o arquivo inteiro com o último código
- `<leader>cd`: Mostra um diff antes de aplicar
- `<leader>ca`: Abre o preview do último código

## 💡 Dicas e Truques

### Prompts Efetivos
```
"Refatore esta função para ser mais legível"
"Adicione tratamento de erro neste código"
"Converta este código para TypeScript"
"Otimize esta função para performance"
"Adicione documentação JSDoc"
```

### Seleção Visual
1. Selecione código no modo visual
2. Pressione `<leader>cp`
3. O código selecionado será incluído automaticamente no contexto

### Múltiplos Arquivos
1. Use `<leader>cf` com Telescope para seleção rápida
2. Selecione múltiplos arquivos com `Ctrl+a` no Telescope
3. O Claude verá todo o contexto do projeto

### Aplicação Segura
- Sempre use `<leader>cd` para ver mudanças antes de aplicar
- Mantenha backups ou use controle de versão
- Teste em arquivos pequenos primeiro

## 🔧 Solução de Problemas

### API Key não encontrada
```bash
# Método recomendado: Variável de ambiente permanente
echo 'export ANTHROPIC_API_KEY="sua-chave-aqui"' >> ~/.bashrc
# ou para zsh:
echo 'export ANTHROPIC_API_KEY="sua-chave-aqui"' >> ~/.zshrc

# Recarregue o terminal
source ~/.bashrc  # ou ~/.zshrc

# Método alternativo: Configuração direta (não recomendado)
require("nano-pilot").setup({
  api_key = "sua-chave-aqui"  -- evite hardcoding da key
})
```

### Telescope não encontrado
O plugin funciona sem Telescope, mas para melhor experiência:
```lua
-- Instale telescope
use "nvim-telescope/telescope.nvim"
```

### Curl não disponível
O plugin usa `curl` para chamadas da API. Instale com:
```bash
# Ubuntu/Debian
sudo apt install curl

# macOS
brew install curl

# Windows
# Curl já vem no Windows 10+
```

### Janelas não aparecem
Verifique se o terminal suporta janelas flutuantes:
- Use Neovim 0.7+
- Terminal moderno (kitty, alacritty, wezterm)

## 🤝 Contribuindo

1. Fork o projeto
2. Crie uma branch para sua feature (`git checkout -b feature/AmazingFeature`)
3. Commit suas mudanças (`git commit -m 'Add some AmazingFeature'`)
4. Push para a branch (`git push origin feature/AmazingFeature`)
5. Abra um Pull Request

## 📝 Roadmap

- [ ] Suporte a múltiplos modelos (GPT-4, etc.)
- [ ] Templates de prompts customizáveis
- [ ] Integração com LSP para contexto semântico
- [ ] Export/import de conversas
- [ ] Plugins para linguagens específicas
- [ ] Modo offline com modelos locais

## 📄 Licença

Distribuído sob a licença MIT. Veja `LICENSE` para mais informações.

## 🙏 Agradecimentos

- [Anthropic](https://anthropic.com) pela incrível API do Claude
- [Cursor](https://cursor.sh) pela inspiração
- Comunidade Neovim pelos plugins e ferramentas

---

**Nano Pilot** - Transformando Neovim em uma IDE moderna com IA 🚀
