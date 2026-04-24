;;; init.el --- Minimal Emacs Hypervisor bootstrap -*- lexical-binding: t; -*-

(defvar emacs-hypervisor-home-directory
  (file-name-directory
   (or load-file-name buffer-file-name user-init-file user-emacs-directory)))

(defvar emacs-hypervisor-config-file
  (expand-file-name "config.el" emacs-hypervisor-home-directory))

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

(add-to-list 'load-path
             (file-name-as-directory
              (expand-file-name "lisp" emacs-hypervisor-home-directory)))

(require 'emacs-hypervisor-bootstrap)

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
  (setq emacs-hypervisor-context-function
        (lambda ()
          (list
           :session-name "user-home-init"
           :config-file emacs-hypervisor-config-file
           :ui (if noninteractive 'batch 'interactive)
           :transport 's-expression
           :benchmark-enabled nil
           :repo-dir emacs-hypervisor-home-directory)))
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
                             (or (plist-get status :last-process-event)
                                 (plist-get status :shutdown)))
                    (when emacs-hypervisor-open-buffer-on-abnormal-exit
                      (emacs-hypervisor-open-process-buffer)))
                (message "[Hypervisor] session complete: %s"
                         (or (plist-get status :shutdown) :ok)))))))
  (emacs-hypervisor-start
   (list (emacs-hypervisor-resolve-binary) "serve")
   "emacs-hypervisor-init"))

(if (file-exists-p emacs-hypervisor-config-file)
    (progn
      (emacs-hypervisor-start-home-session)
      (unless noninteractive
        (message "[Hypervisor] starting session %s" "user-home-init")))
  (message "[Hypervisor] no config.el found at %s" emacs-hypervisor-config-file))
