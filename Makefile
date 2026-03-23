CONFIG_DIR := $(HOME)/.config/claude-devcontainer
BIN_DIR    := $(HOME)/.local/bin

.PHONY: install build test rebuild

install:
	mkdir -p $(CONFIG_DIR) $(BIN_DIR)
	cp container/Dockerfile container/entrypoint.sh container/git-credential-token $(CONFIG_DIR)/
	chmod +x $(CONFIG_DIR)/entrypoint.sh $(CONFIG_DIR)/git-credential-token
	cp bin/claude-docker $(BIN_DIR)/claude-docker
	chmod +x $(BIN_DIR)/claude-docker

build:
	docker build -t claude-devcontainer $(CONFIG_DIR)/

rebuild:
	docker build --no-cache -t claude-devcontainer $(CONFIG_DIR)/

test:
	docker run --rm -it \
		-e CLAUDE_USER="$$(id -u)" \
		-v $(HOME)/.claude:/home/node/.claude \
		-v $(HOME)/.claude.json:/home/node/.claude.json \
                -v "$$PWD:$$PWD" \
		-w "$$PWD" \
		claude-devcontainer
