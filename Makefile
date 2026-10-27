CONFIG_DIR := $(HOME)/.config/claude-devcontainer
BIN_DIR    := $(HOME)/.local/bin

.PHONY: install build test rebuild help

help:
	@echo "Targets:"
	@echo "  install  Copy files to CONFIG_DIR and BIN_DIR (claude-docker + codex-docker link)"
	@echo "  build    Build the Docker image from CONFIG_DIR"
	@echo "  rebuild  Build the Docker image without cache"
	@echo "  test     Run the container interactively in the current directory"

install:
	git submodule update --init --recursive
	mkdir -p $(CONFIG_DIR) $(BIN_DIR)
	cp container/Dockerfile.full container/entrypoint.sh container/git-credential-token container/settings.json container/statusline.js $(CONFIG_DIR)/
	rm -rf $(CONFIG_DIR)/skills
	cp -r skills $(CONFIG_DIR)/skills
	chmod +x $(CONFIG_DIR)/entrypoint.sh $(CONFIG_DIR)/git-credential-token
	cp bin/claude-docker.sh $(BIN_DIR)/claude-docker
	chmod +x $(BIN_DIR)/claude-docker
	ln -sf claude-docker $(BIN_DIR)/codex-docker

build:
	docker build -t claude-devcontainer -f $(CONFIG_DIR)/Dockerfile.full $(CONFIG_DIR)/

rebuild:
	docker build --no-cache -t claude-devcontainer -f $(CONFIG_DIR)/Dockerfile.full $(CONFIG_DIR)/

test:
	docker run --rm -it \
		-e CLAUDE_USER="$$(id -u)" \
		-v $(HOME)/.claude:/home/node/.claude \
		-v $(HOME)/.claude.json:/home/node/.claude.json \
                -v "$$PWD:$$PWD" \
		-w "$$PWD" \
		claude-devcontainer
