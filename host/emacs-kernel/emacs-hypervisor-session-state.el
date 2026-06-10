;;; emacs-hypervisor-session-state.el --- Session state and observability -*- lexical-binding: t; -*-

(defvar emacs-hypervisor--buffer-name " *emacs-hypervisor*")
(defvar emacs-hypervisor--details-buffer-name " *emacs-hypervisor details*")
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
(defvar emacs-hypervisor--last-error-message nil)
(defvar emacs-hypervisor--shutdown-reason nil)
(defvar emacs-hypervisor--completed nil)
(defvar emacs-hypervisor--finish-notified nil)
(defvar emacs-hypervisor--startup-warnings nil)
(defvar emacs-hypervisor-process-sentinel-function nil)
(defvar emacs-hypervisor-loaded-env-file nil)
(defvar emacs-hypervisor-loaded-env-vars nil)

(defun emacs-hypervisor--report-call (function &rest args)
  (when (fboundp function)
    (apply function args)))

(defun emacs-hypervisor--report-value (function &rest args)
  (when (fboundp function)
    (apply function args)))

(defun emacs-hypervisor--notify-session-finished (&optional proc event)
  "Run the session-finished hooks once for PROC and EVENT."
  (unless emacs-hypervisor--finish-notified
    (setq emacs-hypervisor--finish-notified t)
    (emacs-hypervisor--report-call 'emacs-hypervisor-report-session-finished)
    (when (functionp emacs-hypervisor-process-sentinel-function)
      (funcall emacs-hypervisor-process-sentinel-function proc event))))

(defun emacs-hypervisor-record-startup-warning (kind message &rest details)
  "Record a startup warning with KIND, MESSAGE, and DETAILS."
  (let ((entry (append (list :kind kind :message message) details)))
    (push entry emacs-hypervisor--startup-warnings)
    (emacs-hypervisor--report-call 'emacs-hypervisor-report-refresh)
    entry))

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
  (setq emacs-hypervisor--last-error-message nil)
  (setq emacs-hypervisor--shutdown-reason nil)
  (setq emacs-hypervisor--shutdown-payload nil)
  (setq emacs-hypervisor--completed nil)
  (setq emacs-hypervisor--next-request-id 100000)
  (setq emacs-hypervisor--pending-responses nil)
  (setq emacs-hypervisor--finish-notified nil)
  (setq emacs-hypervisor--startup-warnings nil)
  (setq emacs-hypervisor-loaded-env-file nil)
  (setq emacs-hypervisor-loaded-env-vars nil)
  (setq emacs-hypervisor-process-sentinel-function nil)
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-reset))

(defun emacs-hypervisor--record (direction payload)
  (push (cons direction payload) emacs-hypervisor--message-log))

(defun emacs-hypervisor-live-p ()
  "Return non-nil when the Hypervisor process is live."
  (and (processp emacs-hypervisor--process)
       (process-live-p emacs-hypervisor--process)))

(defun emacs-hypervisor-session-active-p ()
  "Return non-nil when Hypervisor is actively orchestrating a session.

A completed startup session may still have a live process object briefly, but
that should not prevent local config reloads."
  (and (emacs-hypervisor-live-p)
       (not emacs-hypervisor--completed)
       (memq emacs-hypervisor--state '(:starting :running))))

(defun emacs-hypervisor-process-buffer ()
  "Return the Hypervisor process buffer."
  (and (processp emacs-hypervisor--process)
       (process-buffer emacs-hypervisor--process)))

(defun emacs-hypervisor-details-buffer ()
  "Return the buffer used for non-protocol Hypervisor runtime output."
  (get-buffer-create emacs-hypervisor--details-buffer-name))

(defun emacs-hypervisor-open-process-buffer ()
  "Display the Hypervisor process buffer."
  (interactive)
  (let ((buffer (or (emacs-hypervisor-process-buffer)
                    (get-buffer emacs-hypervisor--buffer-name))))
    (unless buffer
      (error "No Hypervisor process buffer is available"))
    (pop-to-buffer buffer)))

(defun emacs-hypervisor-open-details-buffer ()
  "Display the Hypervisor runtime details buffer."
  (interactive)
  (pop-to-buffer (emacs-hypervisor-details-buffer)))

(defun emacs-hypervisor--one-line-message (value)
  "Return the first line of VALUE formatted as a user-facing message."
  (when value
    (car (split-string (format "%s" value) "[\r\n]+" t))))

(defun emacs-hypervisor-failure-summary (&optional status)
  "Return the best short failure summary from STATUS or current state."
  (let* ((status (or status (emacs-hypervisor-status)))
         (last-log (plist-get status :last-log)))
    (or (emacs-hypervisor--one-line-message
         (plist-get status :last-error))
        (emacs-hypervisor--one-line-message
         (plist-get last-log :message))
        (emacs-hypervisor--one-line-message
         (plist-get status :shutdown))
        (emacs-hypervisor--one-line-message
         (plist-get status :last-process-event)))))

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
    :session-ms (emacs-hypervisor--report-value 'emacs-hypervisor-report-session-elapsed-ms))
   (list :hypervisor (or (emacs-hypervisor--report-value 'emacs-hypervisor-report-metrics-summary)
                         '(:count 0 :elle-count 0 :emacs-rpc-count 0 :runtime-count 0
                           :session-wall-ms 0 :elle-ms 0 :emacs-rpc-ms 0
                           :emacs-eval-ms 0 :packages-ms 0 :known-ms 0
                           :unattributed-ms 0)))))

(defun emacs-hypervisor-status ()
  "Return a compact status plist for the current Hypervisor session."
  (list
   :state emacs-hypervisor--state
   :live (emacs-hypervisor-live-p)
   :active (emacs-hypervisor-session-active-p)
   :completed emacs-hypervisor--completed
   :shutdown emacs-hypervisor--shutdown-reason
   :last-process-event emacs-hypervisor--last-process-event
   :last-progress emacs-hypervisor--last-progress-message
   :last-log emacs-hypervisor--last-log-message
   :last-error emacs-hypervisor--last-error-message
   :warnings (reverse (copy-sequence emacs-hypervisor--startup-warnings))
   :timings (emacs-hypervisor-startup-metrics)
   :reports (length emacs-hypervisor--report-messages)
   :messages (length emacs-hypervisor--message-log)))

(defun emacs-hypervisor-readiness ()
  "Return the public readiness state for external launchers.

The return value is one of:

- `ready' when the Hypervisor startup session completed successfully.
- `failed' when the Hypervisor startup session completed with a failure.
- `loading' while startup has not finished yet.

External clients such as Hammerspoon should use this function instead of
reading private Hypervisor session variables."
  (cond
   ((and emacs-hypervisor--completed
         (eq emacs-hypervisor--state :completed))
    'ready)
   ((and emacs-hypervisor--completed
         (eq emacs-hypervisor--state :failed))
    'failed)
   (t
    'loading)))

(provide 'emacs-hypervisor-session-state)
