;;; emacs-hypervisor-bootstrap.el --- Minimal trusted bootstrap -*- lexical-binding: t; -*-

(defvar emacs-hypervisor-context-function #'emacs-hypervisor-default-context)
(defvar emacs-hypervisor-session-data-function #'emacs-hypervisor-default-session-data)
(defvar emacs-hypervisor--stderr-buffer-name " *emacs-hypervisor stderr*")

(require 'emacs-hypervisor-session-state)
(require 'emacs-hypervisor-sexp-rpc)

(defun emacs-hypervisor-default-context ()
  (list
   :emacs-version emacs-version
   :system-type system-type
   :user-emacs-directory user-emacs-directory))

(defun emacs-hypervisor-default-session-data (&optional _fields)
  nil)

(defun emacs-hypervisor-load-envvars-file (file &optional noerror)
  "Read and set envvars from FILE.
If NOERROR is non-nil, don't throw an error if the file doesn't exist or is
unreadable. Returns the names of envvars that were changed."
  (if (null (file-exists-p file))
      (unless noerror
        (signal 'file-error (list "No envvar file exists" file)))
    (with-temp-buffer
      (insert-file-contents file)
      (when-let ((env (read (current-buffer))))
        (let ((tz (getenv-internal "TZ")))
          (setq-default
           process-environment
           (append env (default-value 'process-environment))
           exec-path
           (append (split-string (getenv "PATH") path-separator t)
                   (list exec-directory))
           shell-file-name
           (or (getenv "SHELL")
               (default-value 'shell-file-name)))
          (setq emacs-hypervisor-loaded-env-file (expand-file-name file)
                emacs-hypervisor-loaded-env-vars env)
          (when-let ((newtz (getenv-internal "TZ")))
            (unless (equal tz newtz)
              (set-time-zone-rule newtz))))
        env))))

(defun emacs-hypervisor--normalize-process-event (event)
  (replace-regexp-in-string "[\r\n]+\\'" "" event))

(defun emacs-hypervisor--sentinel (proc event)
  (setq emacs-hypervisor--last-process-event
        (emacs-hypervisor--normalize-process-event event))
  (unless (process-live-p proc)
    (unless emacs-hypervisor--completed
      (setq emacs-hypervisor--state :failed)
      (setq emacs-hypervisor--shutdown-reason :process-exited))
    (emacs-hypervisor--report-call 'emacs-hypervisor-report-session-finished)
    (when (functionp emacs-hypervisor-process-sentinel-function)
      (funcall emacs-hypervisor-process-sentinel-function proc event))))

(defun emacs-hypervisor-start (command &optional process-name)
  (let ((buffer (get-buffer-create emacs-hypervisor--buffer-name)))
    (with-current-buffer buffer
      (erase-buffer))
    (setq emacs-hypervisor--state :starting)
    (emacs-hypervisor--report-call 'emacs-hypervisor-report-session-started)
    (setq emacs-hypervisor--process
          (make-process
           :name (or process-name "emacs-hypervisor")
           :buffer buffer
           :command command
           :coding 'utf-8-unix
           :connection-type 'pipe
           :filter #'emacs-hypervisor-sexp-rpc-filter
           :stderr (get-buffer-create emacs-hypervisor--stderr-buffer-name)
           :sentinel #'emacs-hypervisor--sentinel
           :noquery t))
    emacs-hypervisor--process))

(defun emacs-hypervisor-wait-for-completion (&optional timeout-seconds)
  "Wait for the current Hypervisor process to complete.

When TIMEOUT-SECONDS is non-nil, stop waiting after that many seconds.
Return non-nil when a `:shutdown' message was received."
  (let ((deadline (and timeout-seconds
                       (+ (float-time) timeout-seconds))))
    (while (and (not emacs-hypervisor--completed)
                (processp emacs-hypervisor--process)
                (process-live-p emacs-hypervisor--process)
                (or (null deadline)
                    (< (float-time) deadline)))
      (accept-process-output emacs-hypervisor--process 0.1))
    (while (and (processp emacs-hypervisor--process)
                (accept-process-output emacs-hypervisor--process 0.05)))
    emacs-hypervisor--completed))

(provide 'emacs-hypervisor-bootstrap)
