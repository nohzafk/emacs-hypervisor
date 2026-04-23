;;; init.el --- Canonical repo-root Hypervisor init -*- lexical-binding: t; -*-

(defvar emacs-hypervisor-repo-init-started-at (float-time)
  "Wall-clock time at which this repo-local `init.el' began loading.")

(defvar emacs-hypervisor-repo-init-finished-at nil
  "Wall-clock time at which this repo-local `init.el' finished loading.")

(defvar emacs-hypervisor-repo-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar emacs-hypervisor-benchmark-enabled nil
  "Non-nil enables Hypervisor startup benchmarking for this session.")

(defvar emacs-hypervisor-config-file
  (expand-file-name "config.el" emacs-hypervisor-repo-directory))

(defvar emacs-hypervisor-config-org-file
  (expand-file-name "config.org" emacs-hypervisor-repo-directory))

(defvar emacs-hypervisor-env-file
  (expand-file-name
   (or (getenv "EMACS_HYPERVISOR_ENV_FILE") "env")
   emacs-hypervisor-repo-directory))

(defvar emacs-hypervisor-backend-file
  (expand-file-name "elle/hypervisor.lisp" emacs-hypervisor-repo-directory))

(defvar emacs-hypervisor-elle-binary
  (expand-file-name
   (or (getenv "ELLE_BIN") ".elle/target/release/elle")
   emacs-hypervisor-repo-directory))

(defvar emacs-hypervisor-open-buffer-on-abnormal-exit t)

(setq default-directory emacs-hypervisor-repo-directory)
(setq user-emacs-directory
      (file-name-as-directory (expand-file-name emacs-hypervisor-repo-directory)))

(add-to-list
 'load-path
 (file-name-as-directory
  (expand-file-name "lisp" emacs-hypervisor-repo-directory)))

(require 'emacs-hypervisor-bootstrap)

(defun emacs-hypervisor-start-repo-session ()
  "Start a fresh Hypervisor session for the repo-root config."
  (when (emacs-hypervisor-live-p)
    (user-error "Hypervisor session is still running"))
  (unless (file-exists-p emacs-hypervisor-config-file)
    (error "Hypervisor init requires a config file: %s"
           emacs-hypervisor-config-file))
  (emacs-hypervisor-reset)
  (emacs-hypervisor-load-envvars-file emacs-hypervisor-env-file t)
  (setq emacs-hypervisor-context-function
        (lambda ()
          (list
           :session-name "repo-root-init"
           :config-file emacs-hypervisor-config-file
           :ui (if noninteractive 'batch 'interactive)
           :transport 's-expression
           :benchmark-enabled emacs-hypervisor-benchmark-enabled
           :repo-dir emacs-hypervisor-repo-directory)))
  (setq emacs-hypervisor-session-data-function
        (lambda (&optional fields)
          (when (fboundp 'emacs-hypervisor-export-session-data)
            (emacs-hypervisor-export-session-data fields))))
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
   (list emacs-hypervisor-elle-binary emacs-hypervisor-backend-file)
   "emacs-hypervisor-init"))

(emacs-hypervisor-start-repo-session)

(setq emacs-hypervisor-repo-init-finished-at (float-time))

(when (not noninteractive)
  (message "[Hypervisor] starting session %s" "repo-root-init"))
