;;; emacs-hypervisor-package-runtime.el --- Package runtime helpers -*- lexical-binding: t; -*-

(require 'cl-lib)

(defvar emacs-hypervisor-runtime-compat-enabled nil)
(defvar emacs-hypervisor-runtime-package-timeout-seconds nil)
(defvar emacs-hypervisor-runtime-package-timeout-timer nil)
(defvar emacs-hypervisor-runtime-packages-installation-active nil)
(defvar emacs-hypervisor-runtime-packages-finished-sent nil)

(defun emacs-hypervisor-runtime-send-package-installed (name)
  (emacs-hypervisor-send-event
   :package
   (list :phase :packages :kind :installed :name name)))

(defun emacs-hypervisor-runtime-note-package-event (kind &optional name reason)
  (when (fboundp 'emacs-hypervisor-report-note-package-event)
    (emacs-hypervisor-report-note-package-event kind name reason)))

(defun emacs-hypervisor-runtime-send-packages-finished (&optional reason)
  (emacs-hypervisor-send-event
   :package
   (append
    '(:phase :packages :kind :finished)
    (when reason (list :reason reason)))))

(defun emacs-hypervisor-runtime-send-package-timeout (&optional reason)
  (emacs-hypervisor-send-event
   :package
   (append
    '(:phase :packages :kind :timeout)
    (when reason (list :reason reason)))))

(defun emacs-hypervisor-runtime-package-installed (name)
  (push name emacs-hypervisor-installed-packages)
  (push (list :phase :packages :event :installed :name name)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :installed name)
  (emacs-hypervisor-runtime-send-package-installed name))

(defun emacs-hypervisor-runtime-packages-finished (&optional reason)
  (push (list :phase :packages :event :finished :reason reason)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :finished nil reason)
  (emacs-hypervisor-runtime-send-packages-finished reason))

(defun emacs-hypervisor-runtime-packages-timeout (&optional reason)
  (push (list :phase :packages :event :timeout :reason reason)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :timeout nil reason)
  (emacs-hypervisor-runtime-send-package-timeout reason))

(defun emacs-hypervisor-runtime-cancel-package-timeout ()
  (when emacs-hypervisor-runtime-package-timeout-timer
    (cancel-timer emacs-hypervisor-runtime-package-timeout-timer)
    (setq emacs-hypervisor-runtime-package-timeout-timer nil)))

(defun emacs-hypervisor-runtime-package-timeout ()
  (setq emacs-hypervisor-runtime-package-timeout-timer nil)
  (when emacs-hypervisor-runtime-packages-installation-active
    (setq emacs-hypervisor-runtime-packages-installation-active nil)
    (setq emacs-hypervisor-runtime-packages-finished-sent t)
    (emacs-hypervisor-runtime-packages-timeout "timeout")))

(defun emacs-hypervisor-runtime-start-package-timeout ()
  (emacs-hypervisor-runtime-cancel-package-timeout)
  (when emacs-hypervisor-runtime-package-timeout-seconds
    (setq emacs-hypervisor-runtime-package-timeout-timer
          (run-at-time emacs-hypervisor-runtime-package-timeout-seconds
                       nil
                       #'emacs-hypervisor-runtime-package-timeout))))

(defun emacs-hypervisor-runtime-begin-package-installation ()
  (setq emacs-hypervisor-runtime-packages-installation-active t)
  (setq emacs-hypervisor-runtime-packages-finished-sent nil)
  (emacs-hypervisor-runtime-note-package-event :begin)
  (emacs-hypervisor-runtime-start-package-timeout))

(defun emacs-hypervisor-runtime-reset-package-timeout ()
  (when (and emacs-hypervisor-runtime-packages-installation-active
             emacs-hypervisor-runtime-package-timeout-timer)
    (emacs-hypervisor-runtime-start-package-timeout)))

(defun emacs-hypervisor-runtime-report-package-installed (name)
  (when emacs-hypervisor-runtime-packages-installation-active
    (emacs-hypervisor-runtime-reset-package-timeout)
    (emacs-hypervisor-runtime-package-installed name)))

(defun emacs-hypervisor-runtime-notify-packages-finished (&optional reason)
  (when emacs-hypervisor-runtime-packages-installation-active
    (unless emacs-hypervisor-runtime-packages-finished-sent
      (setq emacs-hypervisor-runtime-packages-finished-sent t)
      (setq emacs-hypervisor-runtime-packages-installation-active nil)
      (emacs-hypervisor-runtime-cancel-package-timeout)
      (emacs-hypervisor-runtime-packages-finished reason))))

(defun emacs-hypervisor-runtime-queues-finished ()
  (emacs-hypervisor-runtime-notify-packages-finished "completed"))

(defun emacs-hypervisor-runtime-package-callback (name)
  (emacs-hypervisor-runtime-report-package-installed name))

(defun emacs-hypervisor-runtime-process-packages ()
  (push (list :phase :packages :event :process-queues)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-begin-package-installation)
  (elpaca-process-queues)
  :processing)

(emacs-hypervisor-runtime-cancel-package-timeout)
(setq emacs-hypervisor-runtime-packages-installation-active nil)
(setq emacs-hypervisor-runtime-packages-finished-sent nil)

(emacs-hypervisor-elpaca-bootstrap)
(unless emacs-hypervisor-runtime-compat-enabled
  (add-hook 'elpaca-recipe-functions
            #'emacs-hypervisor-elpaca-infer-main-file)
  (advice-add 'elpaca--shared-source-dir
              :around
              #'emacs-hypervisor-elpaca-shared-source-dir)
  (advice-add 'elpaca-source
              :around
              #'emacs-hypervisor-elpaca-wait-for-shared-git-source)
  (advice-add 'elpaca-git--clone
              :around
              #'emacs-hypervisor-elpaca-wait-on-shared-main-before-clone)
  (setq emacs-hypervisor-runtime-compat-enabled t))

(when (boundp 'elpaca--post-queues-hook)
  (remove-hook 'elpaca--post-queues-hook
               #'emacs-hypervisor-runtime-queues-finished)
  (add-hook 'elpaca--post-queues-hook
            #'emacs-hypervisor-runtime-queues-finished))

(provide 'emacs-hypervisor-package-runtime)
