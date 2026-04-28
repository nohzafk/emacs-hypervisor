;;; emacs-hypervisor-report-core.el --- Startup report state and metrics -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar emacs-hypervisor--plan-messages)
(defvar emacs-hypervisor--progress-messages)
(defvar emacs-hypervisor--report-messages)
(defvar emacs-hypervisor--state)
(defvar emacs-hypervisor--last-progress-message)
(defvar emacs-hypervisor--shutdown-reason)
(defvar emacs-hypervisor--completed)

(defvar emacs-hypervisor-show-report-on-startup nil
  "When non-nil, display the startup report buffer during startup.
The report always appears when a config-unit fails, regardless of this setting.")

(defvar emacs-hypervisor-display-initial-buffer-on-finish t
  "When non-nil, display `initial-buffer-choice' after a clean startup.
This applies only when `emacs-hypervisor-show-report-on-startup' is nil.")

(defvar emacs-hypervisor--session-started-at nil)
(defvar emacs-hypervisor--session-finished-at nil)
(defvar emacs-hypervisor--package-events nil)
(defvar emacs-hypervisor--unit-events nil)
(defvar emacs-hypervisor--metric-events nil)
(defvar emacs-hypervisor--package-installation-active nil)
(defvar emacs-hypervisor--package-installation-started-at nil)
(defvar emacs-hypervisor--package-finished-reason nil)
(defvar emacs-hypervisor--running-unit-name nil)
(defvar emacs-hypervisor--report-startup-opened nil)

(defun emacs-hypervisor-report-refresh ()
  (when (fboundp 'emacs-hypervisor--refresh-report-buffer)
    (emacs-hypervisor--refresh-report-buffer)))

(defun emacs-hypervisor-report-maybe-open ()
  (when (fboundp 'emacs-hypervisor-open-report-buffer)
    (emacs-hypervisor-open-report-buffer)))

(defun emacs-hypervisor-report-maybe-open-on-startup ()
  "Display the report once during startup when configured."
  (when (and emacs-hypervisor-show-report-on-startup
             (not emacs-hypervisor--report-startup-opened)
             (not noninteractive))
    (setq emacs-hypervisor--report-startup-opened t)
    (emacs-hypervisor-report-maybe-open)))

(defun emacs-hypervisor-report--buffer-from-initial-choice (choice)
  "Return the buffer requested by initial buffer CHOICE, when any."
  (condition-case err
      (cond
       ((bufferp choice) choice)
       ((stringp choice) (get-buffer-create choice))
       ((eq choice t) (get-buffer-create "*scratch*"))
       ((functionp choice)
        (let* ((window (selected-window))
               (before-buffer (and (window-live-p window)
                                   (window-buffer window)))
               (value (funcall choice)))
          (cond
           ((bufferp value) value)
           ((stringp value) (get-buffer-create value))
           ((and (window-live-p window)
                 (not (eq before-buffer (window-buffer window))))
            (window-buffer window))
           (t nil))))
       (t nil))
    (error
     (message "[Hypervisor] initial-buffer-choice failed: %s" err)
     nil)))

(defun emacs-hypervisor-report--elpaca-log-buffer-p (buffer)
  "Return non-nil when BUFFER is the Elpaca startup log buffer."
  (and (bufferp buffer)
       (string= (buffer-name buffer) "*elpaca-log*")))

(defun emacs-hypervisor-report--bury-elpaca-log (&optional replacement)
  "Bury the Elpaca startup log, optionally replacing its window."
  (when-let ((elpaca-buffer (get-buffer "*elpaca-log*")))
    (let ((elpaca-window (get-buffer-window elpaca-buffer t)))
      (bury-buffer elpaca-buffer)
      (when (and elpaca-window (window-live-p elpaca-window))
        (cond
         (replacement
          (set-window-buffer elpaca-window replacement)
          (set-window-prev-buffers elpaca-window nil))
         ((not (one-window-p t))
          (delete-window elpaca-window))
         (t
          (with-selected-window elpaca-window
            (switch-to-prev-buffer elpaca-window 'bury))))))))

(defun emacs-hypervisor-report-display-initial-buffer ()
  "Display the configured initial buffer after Hypervisor finishes cleanly."
  (let ((buffer (emacs-hypervisor-report--buffer-from-initial-choice
                 initial-buffer-choice)))
    (when (emacs-hypervisor-report--elpaca-log-buffer-p buffer)
      (setq buffer nil))
    (when (and (not buffer)
               (get-buffer-window "*elpaca-log*" t))
      (setq buffer (get-buffer-create "*scratch*")))
    (emacs-hypervisor-report--bury-elpaca-log buffer)
    (when (and buffer (not (get-buffer-window buffer t)))
      (pop-to-buffer buffer))))

(defun emacs-hypervisor-report-session-elapsed-seconds ()
  "Return the Hypervisor session wall time in seconds."
  (when emacs-hypervisor--session-started-at
    (- (or emacs-hypervisor--session-finished-at (float-time))
       emacs-hypervisor--session-started-at)))

(defun emacs-hypervisor-report-session-elapsed-ms ()
  "Return the Hypervisor session wall time in milliseconds."
  (when-let ((seconds (emacs-hypervisor-report-session-elapsed-seconds)))
    (* 1000.0 seconds)))

(defun emacs-hypervisor-report-metrics ()
  "Return recorded startup metrics in chronological order."
  (reverse (copy-tree emacs-hypervisor--metric-events)))

(defun emacs-hypervisor--metric-total-ms (&rest predicates)
  (cl-loop for metric in emacs-hypervisor--metric-events
           when (cl-every (lambda (predicate) (funcall predicate metric)) predicates)
           sum (or (plist-get metric :duration-ms) 0.0)))

(defun emacs-hypervisor--metrics-for-source (source)
  (seq-filter
   (lambda (metric) (eq (plist-get metric :source) source))
   (emacs-hypervisor-report-metrics)))

(defun emacs-hypervisor--slow-metrics (&optional limit)
  (seq-take
   (sort (emacs-hypervisor-report-metrics)
         (lambda (left right)
           (> (or (plist-get left :duration-ms) 0.0)
              (or (plist-get right :duration-ms) 0.0))))
   (or limit 8)))

(defun emacs-hypervisor-report-metrics-summary ()
  "Return a compact summary of recorded startup metrics."
  (let* ((session-wall-ms (emacs-hypervisor-report-session-elapsed-ms))
         (elle-ms (emacs-hypervisor--metric-total-ms
                   (lambda (metric) (eq (plist-get metric :source) :elle))))
         (emacs-rpc-ms (emacs-hypervisor--metric-total-ms
                        (lambda (metric) (eq (plist-get metric :source) :emacs-rpc))))
         (emacs-eval-ms (emacs-hypervisor--metric-total-ms
                         (lambda (metric) (eq (plist-get metric :source) :emacs-rpc))
                         (lambda (metric) (eq (plist-get metric :op) :eval))))
         (packages-ms (emacs-hypervisor--metric-total-ms
                       (lambda (metric) (eq (plist-get metric :source) :emacs-runtime))))
         (known-ms (+ elle-ms emacs-rpc-ms packages-ms)))
    (list
     :count (length emacs-hypervisor--metric-events)
     :elle-count (length (emacs-hypervisor--metrics-for-source :elle))
     :emacs-rpc-count (length (emacs-hypervisor--metrics-for-source :emacs-rpc))
     :runtime-count (length (emacs-hypervisor--metrics-for-source :emacs-runtime))
     :session-wall-ms session-wall-ms
     :elle-ms elle-ms
     :emacs-rpc-ms emacs-rpc-ms
     :emacs-eval-ms emacs-eval-ms
     :packages-ms packages-ms
     :known-ms known-ms
     :unattributed-ms (and session-wall-ms (max 0.0 (- session-wall-ms known-ms))))))

(defun emacs-hypervisor-report-reset ()
  "Reset report state for a fresh startup session."
  (setq emacs-hypervisor--session-started-at nil)
  (setq emacs-hypervisor--session-finished-at nil)
  (setq emacs-hypervisor--package-events nil)
  (setq emacs-hypervisor--unit-events nil)
  (setq emacs-hypervisor--metric-events nil)
  (setq emacs-hypervisor--package-installation-active nil)
  (setq emacs-hypervisor--package-installation-started-at nil)
  (setq emacs-hypervisor--package-finished-reason nil)
  (setq emacs-hypervisor--running-unit-name nil)
  (setq emacs-hypervisor--report-startup-opened nil)
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-session-started ()
  "Mark the start of a startup session."
  (setq emacs-hypervisor--session-started-at (float-time))
  (setq emacs-hypervisor--session-finished-at nil)
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-session-finished ()
  "Mark the end of a startup session."
  (setq emacs-hypervisor--session-finished-at (float-time))
  (emacs-hypervisor-report-refresh)
  (when (and (eq emacs-hypervisor--state :completed)
             (not noninteractive))
    (when (and (not emacs-hypervisor-show-report-on-startup)
               emacs-hypervisor-display-initial-buffer-on-finish)
      (emacs-hypervisor-report-display-initial-buffer))))

(defun emacs-hypervisor-report-note-plan ()
  "Refresh the report after a new plan message."
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-progress ()
  "Refresh the report after a new progress message."
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-log ()
  "Refresh the report after a new log message."
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-report ()
  "Refresh the report after a new report message."
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-metric (source name duration-ms &rest details)
  "Record a startup metric for SOURCE and NAME lasting DURATION-MS."
  (push (append (list :source source
                      :name name
                      :duration-ms duration-ms
                      :time (float-time))
                details)
        emacs-hypervisor--metric-events)
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-package-event (kind &optional name reason)
  "Record a local package event for the startup report."
  (push (delq nil (list :kind kind
                        :name name
                        :reason reason
                        :time (float-time)))
        emacs-hypervisor--package-events)
  (pcase kind
    (:begin
     (setq emacs-hypervisor--package-installation-active t)
     (setq emacs-hypervisor--package-installation-started-at (float-time))
     (setq emacs-hypervisor--package-finished-reason nil))
    ((or :finished :timeout)
     (setq emacs-hypervisor--package-installation-active nil)
     (setq emacs-hypervisor--package-finished-reason reason)
     (when (and emacs-hypervisor--package-installation-started-at
                (boundp 'emacs-hypervisor-benchmark-enabled)
                emacs-hypervisor-benchmark-enabled)
       (emacs-hypervisor-report-note-metric
        :emacs-runtime
        :package-installation
        (* 1000.0
           (- (float-time) emacs-hypervisor--package-installation-started-at))
        :metric-kind kind
        :item-name reason)
       (setq emacs-hypervisor--package-installation-started-at nil))
     (emacs-hypervisor-report-maybe-open-on-startup)))
  (emacs-hypervisor-report-refresh))

(defun emacs-hypervisor-report-note-unit-event (kind name &optional error)
  "Record a local config-unit event for the startup report."
  (push (delq nil (list :kind kind
                        :name name
                        :error error
                        :time (float-time)))
        emacs-hypervisor--unit-events)
  (pcase kind
    (:attempt
     (setq emacs-hypervisor--running-unit-name name)
     (emacs-hypervisor-report-maybe-open-on-startup))
    ((or :success :failed)
     (when (equal emacs-hypervisor--running-unit-name name)
       (setq emacs-hypervisor--running-unit-name nil))
     (when (and (eq kind :failed) (not noninteractive))
       (emacs-hypervisor-report-maybe-open))))
  (emacs-hypervisor-report-refresh))

(provide 'emacs-hypervisor-report-core)
