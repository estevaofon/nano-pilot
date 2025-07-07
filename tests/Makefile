# Makefile for ailite.nvim tests

# Detectar onde está o busted
BUSTED := $(shell which busted 2>/dev/null)
ifeq ($(BUSTED),)
    # Tentar local installation
    BUSTED := $(HOME)/.luarocks/bin/busted
    ifeq ($(wildcard $(BUSTED)),)
        # Tentar outras localizações comuns
        BUSTED := $(shell find /usr/local/bin /usr/bin ~/.local/bin -name busted 2>/dev/null | head -1)
    endif
endif

# Se ainda não encontrou, usar lua diretamente
ifeq ($(BUSTED),)
    BUSTED := lua $(shell find . -name "busted" -type f 2>/dev/null | head -1)
endif

.PHONY: test test-watch test-coverage deps clean check-deps test-simple

# Verificar dependências
check-deps:
	@echo "Checking test dependencies..."
	@echo "Busted: $(BUSTED)"
	@if [ -z "$(BUSTED)" ] || [ ! -f "$(BUSTED)" ]; then \
		echo "❌ Busted not found!"; \
		echo ""; \
		echo "Try installing with:"; \
		echo "  luarocks install --local busted"; \
		echo "  export PATH=\"$$HOME/.luarocks/bin:$$PATH\""; \
		echo ""; \
		echo "Or run simple tests:"; \
		echo "  make test-simple"; \
		exit 1; \
	else \
		echo "✓ Busted found at: $(BUSTED)"; \
	fi

# Install test dependencies
deps:
	@echo "Installing test dependencies..."
	@luarocks install --local busted || luarocks install busted
	@luarocks install --local luacov || luarocks install luacov
	@luarocks install --local luacov-console || luarocks install luacov-console
	@echo ""
	@echo "Dependencies installed. Add to PATH if needed:"
	@echo "  export PATH=\"$$HOME/.luarocks/bin:$$PATH\""

# Run all tests
test: check-deps
	@echo "Running tests with busted..."
	@cd .. && $(BUSTED) tests

# Alternative: run tests from tests directory
test-here:
	@echo "Running tests..."
	@if [ -f "$(BUSTED)" ]; then \
		$(BUSTED); \
	else \
		echo "Busted not found, using simple runner..."; \
		lua simple_test_runner.lua; \
	fi

# Run tests with simple runner (no dependencies)
test-simple:
	@echo "Running tests with simple runner..."
	@if [ -f "simple_test_runner.lua" ]; then \
		lua simple_test_runner.lua; \
	else \
		echo "Creating simple test runner..."; \
		echo "Run the install script first to create simple_test_runner.lua"; \
	fi

# Run tests in watch mode
test-watch: check-deps
	@echo "Running tests in watch mode..."
	@$(BUSTED) --repeat

# Run tests with coverage
test-coverage: check-deps
	@echo "Running tests with coverage..."
	@$(BUSTED) --coverage
	@luacov-console ./
	@luacov-console -s

# Run specific test file
test-file: check-deps
	@echo "Running test file: $(FILE)"
	@$(BUSTED) $(FILE)

# Clean test artifacts
clean:
	@echo "Cleaning test artifacts..."
	@rm -f luacov.stats.out
	@rm -f luacov.report.out

# Run CI tests
# Run all tests in the tests directory
test-ci: check-deps
	@echo "Running CI tests..."
	@$(BUSTED) --output=TAP --tap-file=tests.tap --no-summary --no-path --no-colors tests

# Show help
help:
	@echo "Available commands:"
	@echo "  make deps         - Install test dependencies"
	@echo "  make test         - Run all tests with busted"
	@echo "  make test-simple  - Run tests with simple runner (no deps)"
	@echo "  make test-here    - Run tests from current directory"
	@echo "  make test-watch   - Run tests in watch mode"
	@echo "  make test-coverage - Run tests with coverage"
	@echo "  make check-deps   - Check if dependencies are installed"
	@echo "  make clean        - Clean test artifacts"
	@echo ""
	@echo "If busted is not found, try:"
	@echo "  export PATH=\"$$HOME/.luarocks/bin:$$PATH\""
