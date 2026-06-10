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
(setq package-user-dir (expand-file-name "packages/" user-emacs-directory))

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

(defun emacs-hypervisor--generated-init-file-p ()
  "Return non-nil when the current init.el is Hypervisor-generated."
  (let ((init-file (emacs-hypervisor--generated-init-file)))
    (when (file-exists-p init-file)
      (with-temp-buffer
        (insert-file-contents init-file nil 0 4096)
        (goto-char (point-min))
        (re-search-forward "^;; emacs-hypervisor-generated: t$" nil t)))))

(defun emacs-hypervisor--init-metadata ()
  "Return metadata about the generated init.el used for boot policy."
  (list
   :init-file (emacs-hypervisor--generated-init-file)
   :init-generated (not (null (emacs-hypervisor--generated-init-file-p)))
   :init-content-hash (emacs-hypervisor--current-init-content-hash)))

(defun emacs-hypervisor--check-mode-p ()
  "Return non-nil when this startup is an `emacs-hypervisor check' run."
  (equal (getenv "EMACS_HYPERVISOR_CHECK") "1"))

(defun emacs-hypervisor--check-strict-p ()
  (equal (getenv "EMACS_HYPERVISOR_CHECK_STRICT") "1"))

(defun emacs-hypervisor--check-format ()
  (or (getenv "EMACS_HYPERVISOR_CHECK_FORMAT") "human"))

(defun emacs-hypervisor--check-describe-source (source)
  (let ((file (plist-get source :file))
        (heading (plist-get source :heading))
        (line (plist-get source :line)))
    (when file
      (concat (file-name-nondirectory file)
              (when heading (format " · %s" heading))
              (when line (format " · line %s" line))))))

(defun emacs-hypervisor--check-render-problem (phase item)
  (princ (format "%-8s %s %-22s %s%s%s\n"
                 (upcase (substring (symbol-name
                                     (or (plist-get item :status) :invalid))
                                    1))
                 phase
                 (or (plist-get item :name) "?")
                 (or (plist-get item :reason) "")
                 (let ((details (plist-get item :details)))
                   (if details (format " %S" details) ""))
                 (let ((location (emacs-hypervisor--check-describe-source
                                  (plist-get item :source))))
                   (if location (format " [%s]" location) "")))))

(defun emacs-hypervisor--check-render-lint (finding)
  (princ (format "%-8s unit %-22s %s (%s)%s\n"
                 (if (eq (plist-get finding :severity) :error) "INVALID" "WARN")
                 (or (plist-get finding :unit) "?")
                 (or (plist-get finding :message) "")
                 (or (plist-get finding :rule) "")
                 (let ((location (emacs-hypervisor--check-describe-source
                                  (plist-get finding :source))))
                   (if location (format " [%s]" location) "")))))

(defun emacs-hypervisor--check-exit-code (payload)
  "Return the exit code for a check shutdown PAYLOAD."
  (let* ((check (plist-get payload :check))
         (lint (plist-get check :lint))
         (lint-errors (cl-count :error lint
                                :key (lambda (f) (plist-get f :severity))))
         (lint-warnings (cl-count-if-not
                         (lambda (f) (eq (plist-get f :severity) :error))
                         lint))
         (problems (+ (length (plist-get check :package-problems))
                      (length (plist-get check :unit-problems))
                      lint-errors)))
    (cond
     ((> problems 0) 1)
     ((and (emacs-hypervisor--check-strict-p) (> lint-warnings 0)) 1)
     (t 0))))

(defun emacs-hypervisor--check-render-human (payload)
  (let* ((check (plist-get payload :check))
         (package-problems (plist-get check :package-problems))
         (unit-problems (plist-get check :unit-problems))
         (lint (plist-get check :lint))
         (problems (+ (length package-problems) (length unit-problems)))
         (lint-errors (cl-count :error lint
                                :key (lambda (f) (plist-get f :severity)))))
    (princ (format "emacs-hypervisor check: %d problem%s, %d lint finding%s\n\n"
                   (+ problems lint-errors)
                   (if (= (+ problems lint-errors) 1) "" "s")
                   (length lint)
                   (if (= (length lint) 1) "" "s")))
    (dolist (item package-problems)
      (emacs-hypervisor--check-render-problem "package" item))
    (dolist (item unit-problems)
      (emacs-hypervisor--check-render-problem "unit" item))
    (dolist (finding lint)
      (emacs-hypervisor--check-render-lint finding))
    (princ (format "\nchecked: %s packages, %s units\n"
                   (or (plist-get check :packages-total) 0)
                   (or (plist-get check :units-total) 0)))))

(defun emacs-hypervisor--check-finish ()
  "Wait for the check session, render the verdict, and exit Emacs."
  (require 'cl-lib)
  (emacs-hypervisor-wait-for-completion 300)
  (let ((payload emacs-hypervisor--shutdown-payload))
    (cond
     ((null payload)
      (princ (format "emacs-hypervisor check: session did not complete: %s\n"
                     (or emacs-hypervisor--last-process-event
                         emacs-hypervisor--last-error-message
                         "no shutdown received")))
      (kill-emacs 2))
     ((eq (plist-get payload :reason) :check-complete)
      (if (equal (emacs-hypervisor--check-format) "sexp")
          (let ((print-length nil) (print-level nil))
            (prin1 payload)
            (princ "\n"))
        (emacs-hypervisor--check-render-human payload))
      (kill-emacs (emacs-hypervisor--check-exit-code payload)))
     (t
      ;; A non-check shutdown, e.g. :config-load-failed.  The config being
      ;; unloadable is a finding, not a harness error.
      (princ (format "emacs-hypervisor check: %s\n%s\n"
                     (or (plist-get payload :reason) :failed)
                     (or (plist-get payload :message)
                         (plist-get payload :details)
                         "")))
      (kill-emacs 1)))))

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
          (let ((init-metadata (emacs-hypervisor--init-metadata)))
            (append
             (list
              :session-name "user-home-init"
              :config-file emacs-hypervisor-config-file
              :ui (if noninteractive 'batch 'interactive)
              :transport 's-expression
              :benchmark-enabled nil
              :repo-dir emacs-hypervisor-home-directory
              :binary emacs-hypervisor-binary)
             init-metadata
             (when (emacs-hypervisor--check-mode-p)
               (list :check t))
             (when (file-exists-p emacs-hypervisor-config-org-file)
               (list :config-org-file emacs-hypervisor-config-org-file))))))
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
  (when (and noninteractive (emacs-hypervisor--check-mode-p))
    (princ (format "emacs-hypervisor check: no config.org or config.el found at %s\n"
                   (emacs-hypervisor--config-directory)))
    (kill-emacs 2))
  (message "[Hypervisor] no config.org or config.el found at %s"
           (emacs-hypervisor--config-directory))))

(when (and noninteractive
           (emacs-hypervisor--check-mode-p)
           (emacs-hypervisor-live-p))
  (emacs-hypervisor--check-finish))
