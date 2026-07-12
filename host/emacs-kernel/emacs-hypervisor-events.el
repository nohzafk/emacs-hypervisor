;;; emacs-hypervisor-events.el --- Hypervisor event topic handlers -*- lexical-binding: t; -*-

(require 'emacs-hypervisor-session-state)

(defvar emacs-hypervisor--process nil)
(defvar emacs-hypervisor--plan-messages nil)
(defvar emacs-hypervisor--progress-messages nil)
(defvar emacs-hypervisor--log-messages nil)
(defvar emacs-hypervisor--report-messages nil)
(defvar emacs-hypervisor--state :idle)
(defvar emacs-hypervisor--last-progress-message nil)
(defvar emacs-hypervisor--last-log-message nil)
(defvar emacs-hypervisor--last-error-message nil)
(defvar emacs-hypervisor--shutdown-reason nil)
(defvar emacs-hypervisor--shutdown-payload nil)
(defvar emacs-hypervisor--completed nil)
(defvar emacs-hypervisor--ready nil)

(declare-function emacs-hypervisor--notify-session-finished "emacs-hypervisor-session-state")
(declare-function emacs-hypervisor--report-call "emacs-hypervisor-session-state")
(declare-function emacs-hypervisor-benchmark-enabled-p "emacs-hypervisor-session-state")
(declare-function emacs-hypervisor-record-startup-warning "emacs-hypervisor-session-state")

(defconst emacs-hypervisor-events--handlers
  '((:warning . emacs-hypervisor-events--handle-warning)
    (:plan . emacs-hypervisor-events--handle-plan)
    (:progress . emacs-hypervisor-events--handle-progress)
    (:log . emacs-hypervisor-events--handle-log)
    (:report . emacs-hypervisor-events--handle-report)
    (:package . emacs-hypervisor-events--handle-package)
    (:metric . emacs-hypervisor-events--handle-metric)
    (:session-ready . emacs-hypervisor-events--handle-session-ready)
    (:shutdown . emacs-hypervisor-events--handle-shutdown))
  "Topic handler table for Hypervisor session events.")

(defun emacs-hypervisor-events--rpc-metric-details (id op payload)
  (append
   (list :op op
         :request-id id)
   (when (eq op :eval)
     (list
      :phase (plist-get payload :phase)
      :metric-kind (or (plist-get payload :metric-kind) :eval)
      :item-name (or (plist-get payload :item-name)
                     (plist-get payload :metric-name))))))

(defun emacs-hypervisor-events-record-rpc-metric (id op payload started-at)
  "Record timing for an inbound RPC request when benchmarking is enabled."
  (when (emacs-hypervisor-benchmark-enabled-p)
    (apply
     #'emacs-hypervisor--report-call
     'emacs-hypervisor-report-note-metric
     :emacs-rpc
     (or (and (eq op :eval)
              (plist-get payload :metric-name))
         op)
     (* 1000.0 (- (float-time) started-at))
     (emacs-hypervisor-events--rpc-metric-details id op payload))))

(defun emacs-hypervisor-events--failed-shutdown-p (payload)
  "Return non-nil when shutdown PAYLOAD represents a failed session."
  (or (eq (plist-get payload :status) :failed)
      (memq (plist-get payload :reason)
            '(:config-load-failed))))

(defun emacs-hypervisor-events--handle-warning (payload)
  (let ((message (or (plist-get payload :message)
                     "startup warning"))
        (kind (or (plist-get payload :kind)
                  :startup))
        (level (or (plist-get payload :level)
                   :warning))
        details)
    (while payload
      (let ((key (pop payload))
            (value (pop payload)))
        (unless (memq key '(:kind :message))
          (setq details (append details (list key value))))))
    (apply #'emacs-hypervisor-record-startup-warning
           kind
           message
           details)
    (unless noninteractive
      (display-warning 'emacs-hypervisor message level)))
  t)

(defun emacs-hypervisor-events--handle-plan (payload)
  (push (append '(:plan) payload) emacs-hypervisor--plan-messages)
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-note-plan)
  t)

(defun emacs-hypervisor-events--handle-progress (payload)
  (setq emacs-hypervisor--last-progress-message
        (append '(:progress) payload))
  (push (append '(:progress) payload) emacs-hypervisor--progress-messages)
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-note-progress)
  t)

(defun emacs-hypervisor-events--handle-log (payload)
  (let ((entry (append '(:log) payload)))
    (setq emacs-hypervisor--last-log-message entry)
    (when (eq (plist-get payload :level) :error)
      (setq emacs-hypervisor--last-error-message
            (plist-get payload :message)))
    (push entry emacs-hypervisor--log-messages))
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-note-log)
  t)

(defun emacs-hypervisor-events--handle-report (payload)
  (push (append '(:report) payload) emacs-hypervisor--report-messages)
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-note-report)
  t)

(defun emacs-hypervisor-events--handle-package (payload)
  (emacs-hypervisor--report-call
   'emacs-hypervisor-report-note-package-event
   (plist-get payload :kind)
   (plist-get payload :name)
   (plist-get payload :reason))
  t)

(defun emacs-hypervisor-events--handle-metric (payload)
  (when (emacs-hypervisor-benchmark-enabled-p)
    (emacs-hypervisor--report-call
     'emacs-hypervisor-report-note-metric
     (or (plist-get payload :source) :elle)
     (or (plist-get payload :name) :metric)
     (or (plist-get payload :duration-ms) 0.0)
     :phase (plist-get payload :phase)
     :metric-kind (plist-get payload :metric-kind)
     :item-name (or (plist-get payload :item-name)
                    (plist-get payload :detail))))
  t)

(defun emacs-hypervisor-events--handle-session-ready (payload)
  "Record that startup completed while the session process keeps running.

Unlike `:shutdown', this must not mark the session completed: the Elle
process stays alive to serve extension calls, and the sentinel still needs
to report a later abnormal exit as `:failed'."
  (setq emacs-hypervisor--ready t)
  (setq emacs-hypervisor--state :completed)
  (emacs-hypervisor--report-call 'emacs-hypervisor-report-session-finished)
  (unless noninteractive
    (message "[Hypervisor] session ready: %s"
             (or (plist-get payload :status) :ready)))
  t)

(defun emacs-hypervisor-events--handle-shutdown (payload)
  (setq emacs-hypervisor--shutdown-reason
        (plist-get payload :reason))
  (setq emacs-hypervisor--shutdown-payload payload)
  (setq emacs-hypervisor--state
        (if (emacs-hypervisor-events--failed-shutdown-p payload)
            :failed
          :completed))
  (setq emacs-hypervisor--completed t)
  (emacs-hypervisor--notify-session-finished
   emacs-hypervisor--process
   (format "%s\n" emacs-hypervisor--shutdown-reason))
  t)

(defun emacs-hypervisor-events-handle (topic payload)
  "Dispatch event TOPIC and PAYLOAD to the registered topic handler."
  (let ((handler (alist-get topic emacs-hypervisor-events--handlers)))
    (when (and handler (fboundp handler))
      (funcall handler payload))))

(provide 'emacs-hypervisor-events)
