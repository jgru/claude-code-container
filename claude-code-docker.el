;;; claude-code-docker.el --- Claude Code via Docker -*- lexical-binding: t; -*-

(add-to-list 'exec-path (expand-file-name "~/.local/bin"))
(setenv "PATH" (concat (expand-file-name "~/.local/bin") ":" (getenv "PATH")))

(use-package claude-code-ide
  :straight (:type git :host github :repo "manzaltu/claude-code-ide.el")
  :bind ("C-c C-'" . claude-code-ide-menu)
  :config
  (setq claude-code-ide-cli-command (expand-file-name "~/.local/bin/claude"))
  (claude-code-ide-emacs-tools-setup))

(defun claude-init-env ()
  "Create a .env template in the project root."
  (interactive)
  (let* ((root (or (vc-root-dir) default-directory))
         (env-file (expand-file-name ".env" root))
         (gitignore (expand-file-name ".gitignore" root)))
    (unless (file-exists-p env-file)
      (with-temp-file env-file
        (insert "GITHUB_TOKEN=\n"
                "# GITLAB_TOKEN=\n"
                "# GIT_AUTHOR_NAME=Your Name\n"
                "# GIT_AUTHOR_EMAIL=you@example.com\n"
                "# CLAUDE_FIREWALL=true\n")))
    (when (file-exists-p gitignore)
      (with-temp-buffer
        (insert-file-contents gitignore)
        (unless (string-match-p "^\\.env$" (buffer-string))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert ".env\n")
          (write-region (point-min) (point-max) gitignore))))
    (find-file env-file)))
