;;; emacs-hypervisor-session.el --- Session state and observability -*- lexical-binding: t; -*-

(defvar emacs-hypervisor--buffer-name " *emacs-hypervisor*")
(defvar emacs-hypervisor--process nil)
(defvar emacs-hypervisor--message-log nil)
(defvar emacs-hypervisor--runtime-dispatch-function nil)
(defvar emacs-hypervisor--hello-message nil)
(defvar emacs-hypervisor--plan-messages nil)
(defvar emacs-hypervisor--progress-messages nil)
(defvar emacs-hypervisor--log-messages nil)
(defvar emacs-hypervisor--report-messages nil)
(defvar emacs-hypervisor--state :idle)
(defvar emacs-hypervisor--last-process-event nil)
(defvar emacs-hypervisor--last-progress-message nil)
(defvar emacs-hypervisor--last-log-message nil)
(defvar emacs-hypervisor--shutdown-reason nil)
(defvar emacs-hypervisor--completed nil)
(defvar emacs-hypervisor-process-sentinel-function nil)
(defvar emacs-hypervisor-loaded-env-file nil)
(defvar emacs-hypervisor-loaded-env-vars nil)

(require 'emacs-hypervisor-report)

(defun emacs-hypervisor-benchmark-enabled-p ()
  "Return non-nil when Hypervisor benchmarking is enabled."
  (and (boundp 'emacs-hypervisor-benchmark-enabled)
       emacs-hypervisor-benchmark-enabled))

(defun emacs-hypervisor-reset ()
  (setq emacs-hypervisor--process nil)
  (setq emacs-hypervisor--message-log nil)
  (setq emacs-hypervisor--runtime-dispatch-function nil)
  (setq emacs-hypervisor--hello-message nil)
  (setq emacs-hypervisor--plan-messages nil)
  (setq emacs-hypervisor--progress-messages nil)
  (setq emacs-hypervisor--log-messages nil)
  (setq emacs-hypervisor--report-messages nil)
  (setq emacs-hypervisor--state :idle)
  (setq emacs-hypervisor--last-process-event nil)
  (setq emacs-hypervisor--last-progress-message nil)
  (setq emacs-hypervisor--last-log-message nil)
  (setq emacs-hypervisor--shutdown-reason nil)
  (setq emacs-hypervisor--completed nil)
  (setq emacs-hypervisor-loaded-env-file nil)
  (setq emacs-hypervisor-loaded-env-vars nil)
  (setq emacs-hypervisor-process-sentinel-function nil)
  (emacs-hypervisor-report-reset))

(defun emacs-hypervisor--record (direction payload)
  (push (cons direction payload) emacs-hypervisor--message-log))

(defun emacs-hypervisor-live-p ()
  "Return non-nil when the Hypervisor process is live."
  (and (processp emacs-hypervisor--process)
       (process-live-p emacs-hypervisor--process)))

(defun emacs-hypervisor-process-buffer ()
  "Return the Hypervisor process buffer."
  (and (processp emacs-hypervisor--process)
       (process-buffer emacs-hypervisor--process)))

(defun emacs-hypervisor-open-process-buffer ()
  "Display the Hypervisor process buffer."
  (interactive)
  (let ((buffer (or (emacs-hypervisor-process-buffer)
                    (get-buffer emacs-hypervisor--buffer-name))))
    (unless buffer
      (error "No Hypervisor process buffer is available"))
    (pop-to-buffer buffer)))

(defun emacs-hypervisor-init-elapsed-ms ()
  "Return the Emacs init duration in milliseconds."
  (cond
   ((and (boundp 'emacs-hypervisor-repo-init-started-at)
         (boundp 'emacs-hypervisor-repo-init-finished-at)
         emacs-hypervisor-repo-init-finished-at)
    (* 1000.0
       (- emacs-hypervisor-repo-init-finished-at
          emacs-hypervisor-repo-init-started-at)))
   ((and (boundp 'before-init-time)
         (boundp 'after-init-time)
         after-init-time)
    (* 1000.0
       (float-time
        (time-subtract after-init-time before-init-time))))))

(defun emacs-hypervisor-startup-metrics ()
  "Return compact startup timing information."
  (append
   (list
    :init-ms (emacs-hypervisor-init-elapsed-ms)
    :session-ms (emacs-hypervisor-report-session-elapsed-ms))
   (list :hypervisor (emacs-hypervisor-report-metrics-summary))))

(defun emacs-hypervisor-status ()
  "Return a compact status plist for the current Hypervisor session."
  (list
   :state emacs-hypervisor--state
   :live (emacs-hypervisor-live-p)
   :completed emacs-hypervisor--completed
   :shutdown emacs-hypervisor--shutdown-reason
   :last-process-event emacs-hypervisor--last-process-event
   :last-progress emacs-hypervisor--last-progress-message
   :last-log emacs-hypervisor--last-log-message
   :timings (emacs-hypervisor-startup-metrics)
   :reports (length emacs-hypervisor--report-messages)
   :messages (length emacs-hypervisor--message-log)))

(provide 'emacs-hypervisor-session)
