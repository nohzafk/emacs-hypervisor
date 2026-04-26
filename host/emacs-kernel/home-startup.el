;;; home-startup.el --- Emacs Hypervisor home startup wrapper -*- lexical-binding: t; -*-

;; This template is appended after the bundled trusted bootstrap modules.

(defvar emacs-hypervisor-home-directory
  (file-name-directory
   (or load-file-name buffer-file-name user-init-file user-emacs-directory)))

(defun emacs-hypervisor--xdg-config-home ()
  "Return the XDG config home directory with HOME/.config fallback."
  (let ((xdg-config-home (getenv "XDG_CONFIG_HOME")))
    (if (and xdg-config-home (not (equal xdg-config-home "")))
        xdg-config-home
      "~/.config")))

(defun emacs-hypervisor--config-directory ()
  "Return the fixed user-owned Hypervisor config directory."
  (file-name-as-directory
   (expand-file-name
    "emacs-hypervisor"
    (emacs-hypervisor--xdg-config-home))))

(defvar emacs-hypervisor-config-file
  (expand-file-name "config.el" (emacs-hypervisor--config-directory)))

(defvar emacs-hypervisor-config-org-file
  (expand-file-name "config.org" (emacs-hypervisor--config-directory)))

(defvar emacs-hypervisor-env-file
  (expand-file-name
   (or (getenv "EMACS_HYPERVISOR_ENV_FILE") "env")
   emacs-hypervisor-home-directory))

(defvar emacs-hypervisor-binary-name
  (or (getenv "EMACS_HYPERVISOR_BIN") "emacs-hypervisor"))

(defvar emacs-hypervisor-binary nil)
(defvar emacs-hypervisor-open-buffer-on-abnormal-exit t)

(setq default-directory emacs-hypervisor-home-directory)
(setq user-emacs-directory
      (file-name-as-directory emacs-hypervisor-home-directory))

;; Bootstrap binary resolution rule:
;; 1. Prefer EMACS_HYPERVISOR_BIN when already set.
;; 2. Otherwise try PATH from the original Emacs launch environment.
;; 3. Load the optional env file.
;; 4. If still unresolved, try EMACS_HYPERVISOR_BIN / PATH again.
;; 5. Cache the absolute path before starting the subprocess.
;; This means the env file can help, but is not required for bootstrap.

(defun emacs-hypervisor-resolve-binary-now ()
  "Resolve `emacs-hypervisor' from the current process environment."
  (or (getenv "EMACS_HYPERVISOR_BIN")
      (executable-find emacs-hypervisor-binary-name)))

(defun emacs-hypervisor-resolve-binary ()
  "Resolve and cache the installed `emacs-hypervisor' binary."
  (or emacs-hypervisor-binary
      (setq emacs-hypervisor-binary
            (or (emacs-hypervisor-resolve-binary-now)
                (user-error
                 (concat "Could not find `emacs-hypervisor' via "
                         "EMACS_HYPERVISOR_BIN or PATH"))))))

(defun emacs-hypervisor--trim-string (value)
  "Return VALUE without leading or trailing ASCII whitespace."
  (replace-regexp-in-string
   "\\`[ \t\r\n]+\\|[ \t\r\n]+\\'" ""
   value))

(defun emacs-hypervisor--generated-init-file ()
  "Return the generated init.el path for the current Hypervisor home."
  (expand-file-name "init.el" emacs-hypervisor-home-directory))

(defun emacs-hypervisor--current-init-content-hash ()
  "Return the content hash recorded in generated init.el, or nil."
  (let ((init-file (emacs-hypervisor--generated-init-file)))
    (when (file-exists-p init-file)
      (with-temp-buffer
        (insert-file-contents init-file nil 0 4096)
        (goto-char (point-min))
        (when (re-search-forward
               "^;; emacs-hypervisor-content-hash: \\(.+\\)$"
               nil
               t)
          (match-string 1))))))

(defun emacs-hypervisor--binary-bootstrap-hash (binary)
  "Ask BINARY for the init.el bootstrap hash it would generate."
  (with-temp-buffer
    (when (= (call-process binary nil t nil "bootstrap-hash") 0)
      (emacs-hypervisor--trim-string (buffer-string)))))

(defun emacs-hypervisor--record-bootstrap-warning (message &rest details)
  "Record and display a bootstrap warning MESSAGE with DETAILS."
  (apply #'emacs-hypervisor-record-startup-warning
         :bootstrap-hash
         message
         details)
  (unless noninteractive
    (message "[Hypervisor] warning: %s" message)))

(defun emacs-hypervisor-check-bootstrap-hash ()
  "Warn when generated init.el does not match the current binary."
  (let* ((binary (emacs-hypervisor-resolve-binary))
         (current-hash (emacs-hypervisor--current-init-content-hash))
         (expected-hash (emacs-hypervisor--binary-bootstrap-hash binary))
         (upgrade-command
          (format "%s init --home %s --upgrade"
                  binary
                  (directory-file-name emacs-hypervisor-home-directory))))
    (cond
     ((and current-hash expected-hash (not (equal current-hash expected-hash)))
      (emacs-hypervisor--record-bootstrap-warning
       (format "generated init.el is stale; run `%s`" upgrade-command)
       :current-hash current-hash
       :expected-hash expected-hash
       :binary binary
       :home emacs-hypervisor-home-directory))
     ((and (null current-hash) expected-hash)
      (emacs-hypervisor--record-bootstrap-warning
       (format "generated init.el has no content hash; run `%s`" upgrade-command)
       :expected-hash expected-hash
       :binary binary
       :home emacs-hypervisor-home-directory))
     ((and current-hash (null expected-hash))
      (emacs-hypervisor--record-bootstrap-warning
       (format "could not read bootstrap hash from `%s`; reinstall the current binary"
               binary)
       :current-hash current-hash
       :binary binary
       :home emacs-hypervisor-home-directory)))))

(defun emacs-hypervisor-empty-session-data (&optional fields)
  "Return an explicit empty session-data payload."
  (let ((requested (or fields '(:packages :units :env)))
        payload)
    (when (memq :packages requested)
      (setq payload (append payload (list :packages ()))))
    (when (memq :units requested)
      (setq payload (append payload (list :units ()))))
    (when (memq :env requested)
      (setq payload (append payload (list :env ()))))
    payload))

(defun emacs-hypervisor-start-home-session ()
  "Start a Hypervisor session for the current Emacs home."
  (when (emacs-hypervisor-live-p)
    (user-error "Hypervisor session is still running"))
  (setq emacs-hypervisor-binary
        (or emacs-hypervisor-binary
            (emacs-hypervisor-resolve-binary-now)))
  (emacs-hypervisor-reset)
  (emacs-hypervisor-load-envvars-file emacs-hypervisor-env-file t)
  (emacs-hypervisor-resolve-binary)
  (emacs-hypervisor-check-bootstrap-hash)
  (setq emacs-hypervisor-context-function
        (lambda ()
          (append
           (list
            :session-name "user-home-init"
            :config-file emacs-hypervisor-config-file
            :ui (if noninteractive 'batch 'interactive)
            :transport 's-expression
            :benchmark-enabled nil
            :repo-dir emacs-hypervisor-home-directory)
           (when (file-exists-p emacs-hypervisor-config-org-file)
             (list :config-org-file emacs-hypervisor-config-org-file)))))
  (setq emacs-hypervisor-session-data-function
        (lambda (&optional fields)
          (or (and (fboundp 'emacs-hypervisor-export-session-data)
                   (emacs-hypervisor-export-session-data fields))
              (emacs-hypervisor-empty-session-data fields))))
  (setq emacs-hypervisor-process-sentinel-function
        (lambda (_proc _event)
          (unless noninteractive
            (let ((status (emacs-hypervisor-status)))
              (if (eq (plist-get status :state) :failed)
                  (progn
                    (message "[Hypervisor] session failed: %s"
                             (or (emacs-hypervisor-failure-summary status)
                                 :failed))
                    (when emacs-hypervisor-open-buffer-on-abnormal-exit
                      (if (fboundp 'emacs-hypervisor-open-report-buffer)
                          (emacs-hypervisor-open-report-buffer)
                        (emacs-hypervisor-open-process-buffer))))
                (message "[Hypervisor] session complete: %s"
                         (or (plist-get status :shutdown) :ok)))))))
  (emacs-hypervisor-start
   (list (emacs-hypervisor-resolve-binary) "serve")
   "emacs-hypervisor-init"))

(cond
 ((file-exists-p emacs-hypervisor-config-org-file)
  (when (file-exists-p emacs-hypervisor-config-file)
    (message "[Hypervisor] both config.org and config.el found; using config.org (config.el is ignored)"))
  (emacs-hypervisor-start-home-session)
  (unless noninteractive
    (message "[Hypervisor] starting session %s (literate config)" "user-home-init")))
 ((file-exists-p emacs-hypervisor-config-file)
  (emacs-hypervisor-start-home-session)
  (unless noninteractive
    (message "[Hypervisor] starting session %s" "user-home-init")))
 (t
  (message "[Hypervisor] no config.org or config.el found at %s"
           (emacs-hypervisor--config-directory))))
