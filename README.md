# 🚀 ailite.nvim

A lightweight, interactive AI coding assistant for Neovim with Claude API integration. Experience a terminal-style chat interface directly in your editor with seamless code application capabilities.

![Neovim](https://img.shields.io/badge/Neovim-0.8+-green.svg)
![Lua](https://img.shields.io/badge/Lua-5.1+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

https://github.com/user-attachments/assets/5f0c5118-55dd-43b3-b676-d9e35a82ac0f

## ✨ Features

- **Interactive Terminal-Style Chat**: Type directly in the chat buffer, no popup windows
- **Claude API Integration**: Powered by Anthropic's Claude AI models
- **Smart Code Management**: Extract, preview, and apply code blocks with multiple options
- **File Context**: Include multiple files in your conversation context
- **Syntax Highlighting**: Native Neovim highlighting for code blocks in chat
- **Visual Selection Support**: Send selected code snippets with context
- **Diff Preview**: Review changes before applying code modifications
- **Persistent History**: Maintain conversation context across prompts

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "estevaofon/ailite.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim", -- Optional, for file selection
  },
  config = function()
    require("ailite").setup({
      api_key = "your-claude-api-key", -- Or use environment variable
      -- Additional configuration options
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "estevaofon/ailite.nvim",
  requires = {
    "nvim-telescope/telescope.nvim", -- Optional
  },
  config = function()
    require("ailite").setup({
      api_key = "your-claude-api-key",
    })
  end,
}
```

## 🔧 Configuration

### Basic Setup
```lua
require("ailite").setup {
  -- API Configuration
  api_key = "your-claude-api-key", -- Set your API key here or use environment variables
}
```
### Custom Configuration
```lua
require("ailite").setup({
  -- API Configuration
  api_key = nil, -- Will check ANTHROPIC_API_KEY or CLAUDE_API_KEY env vars
  model = "claude-3-5-sonnet-20241022",
  max_tokens = 8192,
  temperature = 0.7,
  
  -- Chat Configuration
  history_limit = 20,
  chat_window = {
    width = 100,
    height = 35,
    border = "rounded",
  },
  code_window = {
    width = 80,
    height = 20,
    border = "rounded",
  },
  
  -- Interface Configuration
  chat_input_prefix = ">>> ",
  assistant_prefix = "Ailite: ",
  assistant_name = "AiLite",
  user_prefix = "You: ",
  
  -- Keybindings
  keymaps = {
    send_message = "<C-s>",     -- Send message in insert mode
    apply_code = "<C-a>",       -- Apply code in preview
    copy_code = "<C-c>",        -- Copy code to clipboard
    next_code_block = "<C-n>",  -- Navigate to next code block
    prev_code_block = "<C-p>",  -- Navigate to previous code block
  },
})
```

### Environment Variables

Set your API key via environment variable:

```bash
export ANTHROPIC_API_KEY="your-api-key-here"
# or
export CLAUDE_API_KEY="your-api-key-here"
```

```powershell
$env:ANTHROPIC_API_KEY ="your-api-key-here"
```


## 🎮 Usage

### Basic Commands

| Command | Description |
|---------|-------------|
| `:AiliteChat` | Toggle the chat window |
| `:AilitePrompt` | Quick prompt without opening chat |
| `:AiliteSelectFiles` | Select files to include in context |
| `:AiliteToggleFile` | Toggle current file in context |
| `:AiliteClearChat` | Clear chat history |
| `:AiliteInfo` | Show plugin information |
| `:AiliteHelp` | Show help |

### Default Keybindings

| Mode | Key | Action |
|------|-----|--------|
| Normal | `<leader>cc` | Toggle chat window |
| Normal | `<leader>cp` | Quick prompt |
| Visual | `<leader>cp` | Prompt with selection |
| Normal | `<leader>cf` | Select files for context |
| Normal | `<leader>ct` | Toggle current file |
| Normal | `<leader>ca` | Apply last code block |
| Normal | `<leader>cr` | Replace file with code |
| Normal | `<leader>cd` | Apply with diff preview |

### Chat Interface Keys

| Mode | Key | Action |
|------|-----|--------|
| Normal | `i`, `o`, `a` | Start new message |
| Insert | `Ctrl+S` | Send message |
| Insert | `Esc` | Cancel input |
| Normal | `q` | Close chat |
| Normal | `c` | Clear chat |
| Normal | `t` | Show help |
| Normal | `Ctrl+N` | Next code block |
| Normal | `Ctrl+P` | Previous code block |
| Normal | `Ctrl+A` | Apply code block to file |

## 📝 Interactive Chat Workflow

1. **Open Chat**: Press `<leader>cc` or run `:AiliteChat`
2. **Start Message**: Press `i` to enter input mode
3. **Type Message**: Write your prompt (use Enter for new lines)
4. **Send**: Press `Ctrl+S` to send to Claude
5. **Navigate Code**: Use `Ctrl+N/P` to browse code blocks
6. **Apply Code**: Use `Ctrl+a` to apply the code previewed

### Applying Code Blocks
When Claude provides code in the chat, you can:
1. Navigate between code blocks using `Ctrl+N` and `Ctrl+P`
2. Press `Ctrl+A` to apply the current code block
3. Choose how to apply the code:
   - Replace entire file
   - Insert at cursor position
   - Append to end of file
   - Cancel


## 🔍 Examples

### Basic Code Generation
```
>>> Write a function to calculate fibonacci numbers in Python
```

### Refactoring with Context
```vim
" 1. Select code visually
" 2. Press <leader>cp
" 3. Type your refactoring request
```

### Multiple File Context
```vim
:AiliteSelectFiles    " Select relevant files
:AiliteChat          " Open chat
" Now Claude has context of all selected files
```

## 🎨 Customization

### Window Borders

Customize window borders in your setup:

```lua
chat_window = {
  border = "double", -- rounded, single, double, shadow, none
}
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by [Cursor IDE](https://cursor.sh/) and [avante.nvim](https://github.com/yetone/avante.nvim)
- Powered by [Anthropic's Claude API](https://www.anthropic.com/)
- Built with ❤️ for the Neovim community

## 🧪 Testing

### Running Unit Tests

The project includes comprehensive unit tests to ensure code quality and reliability.

#### Prerequisites

First, install LuaRocks if not already installed:
```bash
# Ubuntu/Debian
sudo apt-get install luarocks

# macOS
brew install luarocks

# Arch Linux
sudo pacman -S luarocks
```

Then install test dependencies:
```bash
# Install test dependencies with luarocks
luarocks install --local busted
luarocks install --local luacov
luarocks install --local luacov-console

# Add to PATH if needed
export PATH="$HOME/.luarocks/bin:$PATH"

# Or use the provided Makefile
cd tests
make deps
```

#### Running Tests
```bash
# Run all tests
cd tests
make test

# Run tests with coverage
make test-coverage

# Run tests in watch mode
make test-watch

# Run specific test file
make test-file FILE=spec/ailite/config_spec.lua
```

#### Alternative: Simple Test Runner
If you don't have `busted` installed:
```bash
# Run tests without dependencies
cd tests
make test-simple
```

#### Available Test Commands
- `make deps` - Install test dependencies (busted, luacov)
- `make test` - Run all tests with busted
- `make test-simple` - Run tests with simple runner (no dependencies)
- `make test-coverage` - Run tests with coverage report
- `make test-watch` - Run tests in watch mode
- `make check-deps` - Check if test dependencies are installed
- `make clean` - Clean test artifacts

## 🐛 Troubleshooting

### API Key Issues
```vim
:AiliteInfo  " Check if API key is configured
```

### Chat Not Opening
- Ensure Neovim version is 0.8+
- Check for conflicts with other plugins
- Run `:checkhealth` for diagnostics

### Code Not Applying
- Make sure the target buffer is modifiable
- Check if the file has write permissions

## 📮 Support

- Report bugs via [GitHub Issues](https://github.com/estevaofon/ailite.nvim/issues)
- Request features through issues with the `enhancement` label
- Join discussions in the [Discussions](https://github.com/estevaofon/ailite.nvim/discussions) tab

## 🤝 Feel Free to Contribute

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Ways to Contribute

- **Bug Reports**: Found a bug? Open an issue with steps to reproduce
- **Feature Requests**: Have an idea? Share it in the issues section
- **Code Contributions**: Submit pull requests for bug fixes or new features

### Development Focus Areas

- Improving code update functionality
- Enhancing the diff preview feature
- Add unit tests for critical components
- Allow other AI models in the future
