;;; claude-code-ide-ext.el --- Claude Code IDE extensions -*- lexical-binding: t; -*-

;; Extends claude-code-ide with Docker wrapper support, named instances
;; for parallel agents, and an optional native (non-dockerized) mode.

;;; Configuration

(defgroup claude-code-ide-ext nil
  "Claude Code IDE extensions."
  :group 'tools
  :prefix "claude-code-ide-ext-")

(defcustom claude-code-ide-ext-docker-cli
  (expand-file-name "~/.local/bin/claude")
  "Path to the dockerized claude-docker wrapper."
  :type 'string)

(defcustom claude-code-ide-ext-bare-cli "claude"
  "Path to the native (non-dockerized) Claude Code CLI."
  :type 'string)

(defcustom claude-code-ide-ext-use-docker t
  "When non-nil use the Docker wrapper, otherwise run Claude Code natively."
  :type 'boolean)

(defcustom claude-code-ide-ext-instances-dir
  (expand-file-name "~/.config/claude-devcontainer/instances/")
  "Directory where named instance state is stored."
  :type 'directory)

(defvar-local claude-code-ide-ext-instance nil
  "Named instance for the current buffer/project.
Set interactively with `claude-code-ide-ext-set-instance' or per-project
via .dir-locals.el:

  ((nil . ((claude-code-ide-ext-instance . \"stan\"))))")

;;; Package setup

(add-to-list 'exec-path (expand-file-name "~/.local/bin"))
(setenv "PATH" (concat (expand-file-name "~/.local/bin") ":" (getenv "PATH")))

(use-package claude-code-ide
  :straight (:type git :host github :repo "manzaltu/claude-code-ide.el")
  :bind ("C-c C-'" . claude-code-ide-menu)
  :config
  (setq claude-code-ide-cli-path claude-code-ide-ext-docker-cli)
  (claude-code-ide-emacs-tools-setup))

;;; Instance helpers

(defun claude-code-ide-ext--instance-names ()
  "Return list of existing instance names."
  (when (file-directory-p claude-code-ide-ext-instances-dir)
    (cl-remove-if
     (lambda (f) (member f '("." "..")))
     (directory-files claude-code-ide-ext-instances-dir nil "^[^.]"))))

(defun claude-code-ide-ext--effective-cli ()
  "Return the CLI path based on `claude-code-ide-ext-use-docker'."
  (if claude-code-ide-ext-use-docker
      claude-code-ide-ext-docker-cli
    claude-code-ide-ext-bare-cli))

(defun claude-code-ide-ext--inject-flags (&rest _)
  "Set `claude-code-ide-cli-path' and inject instance flag before launch."
  (setq claude-code-ide-cli-path (claude-code-ide-ext--effective-cli))
  (let ((base (or claude-code-ide-cli-extra-flags "")))
    ;; Strip any prior -i flag
    (setq base (string-trim (replace-regexp-in-string "-i +[^ ]+" "" base)))
    (setq claude-code-ide-cli-extra-flags
          (if (and claude-code-ide-ext-instance claude-code-ide-ext-use-docker)
              (string-trim (concat (format "-i %s" claude-code-ide-ext-instance)
                                   " " base))
            base))))

(dolist (fn '(claude-code-ide claude-code-ide-continue claude-code-ide-resume))
  (advice-add fn :before #'claude-code-ide-ext--inject-flags))

;;; Interactive commands

(defun claude-code-ide-ext-set-instance (name)
  "Set the Claude instance name for the current buffer."
  (interactive
   (list (completing-read "Instance (empty for default): "
                          (claude-code-ide-ext--instance-names) nil nil)))
  (setq-local claude-code-ide-ext-instance (if (string-empty-p name) nil name))
  (message "Claude instance: %s" (or claude-code-ide-ext-instance "default")))

(defun claude-code-ide-ext-start (instance)
  "Start Claude with a named INSTANCE, completing from existing ones."
  (interactive
   (list (completing-read "Instance: "
                          (claude-code-ide-ext--instance-names) nil nil)))
  (setq-local claude-code-ide-ext-instance
              (if (string-empty-p instance) nil instance))
  (claude-code-ide))

(defun claude-code-ide-ext-list-instances ()
  "Show all Claude instances in a buffer."
  (interactive)
  (let ((buf (get-buffer-create "*claude-instances*"))
        (cmd (concat claude-code-ide-ext-docker-cli " --list")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (shell-command-to-string cmd)))
      (special-mode))
    (display-buffer buf)))

(defun claude-code-ide-ext-prune-instance (name)
  "Prune a stopped Claude instance by NAME."
  (interactive
   (list (completing-read "Prune instance: "
                          (claude-code-ide-ext--instance-names) nil t)))
  (when (yes-or-no-p (format "Prune instance '%s'? " name))
    (message "%s"
             (string-trim
              (shell-command-to-string
               (format "%s -i %s --prune"
                       claude-code-ide-ext-docker-cli
                       (shell-quote-argument name)))))))

(defun claude-code-ide-ext-toggle-docker ()
  "Toggle between dockerized and native Claude Code."
  (interactive)
  (setq claude-code-ide-ext-use-docker (not claude-code-ide-ext-use-docker))
  (message "Claude: %s" (if claude-code-ide-ext-use-docker "docker" "native")))

;;; Project scaffolding

(defun claude-code-ide-ext-init-env ()
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

(provide 'claude-code-ide-ext)
;;; claude-code-ide-ext.el ends here
