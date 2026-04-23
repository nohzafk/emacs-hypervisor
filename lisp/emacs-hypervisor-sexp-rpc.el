;;; emacs-hypervisor-sexp-rpc.el --- S-expression RPC transport -*- lexical-binding: t; -*-

(require 'json)
(require 'emacs-hypervisor-report)

(defconst emacs-hypervisor-protocol-name :sexp-rpc)
(defconst emacs-hypervisor-protocol-version 1)

(defvar emacs-hypervisor--process nil)
(defvar emacs-hypervisor--message-log nil)
(defvar emacs-hypervisor--runtime-dispatch-function nil)
(defvar emacs-hypervisor--hello-message nil)
(defvar emacs-hypervisor--plan-messages nil)
(defvar emacs-hypervisor--progress-messages nil)
(defvar emacs-hypervisor--log-messages nil)
(defvar emacs-hypervisor--report-messages nil)
(defvar emacs-hypervisor--state :idle)
(defvar emacs-hypervisor--last-progress-message nil)
(defvar emacs-hypervisor--last-log-message nil)
(defvar emacs-hypervisor--shutdown-reason nil)
(defvar emacs-hypervisor--completed nil)
(defvar emacs-hypervisor-context-function nil)
(defvar emacs-hypervisor-session-data-function nil)

(declare-function emacs-hypervisor--record "emacs-hypervisor-session")
(declare-function emacs-hypervisor-benchmark-enabled-p "emacs-hypervisor-session")

(defun emacs-hypervisor--sexp-string (value)
  "Serialize VALUE to a single-line S-expression transport string."
  (cond
   ((consp value)
    (concat "("
            (mapconcat #'emacs-hypervisor--sexp-string value " ")
            ")"))
   ((vectorp value)
    (concat "["
            (mapconcat #'emacs-hypervisor--sexp-string value " ")
            "]"))
   ((stringp value)
    (json-serialize value))
   ((keywordp value)
    (symbol-name value))
   ((symbolp value)
    (symbol-name value))
   (t
    (prin1-to-string value))))

(defun emacs-hypervisor-send (message)
  (unless (process-live-p emacs-hypervisor--process)
    (error "Hypervisor process is not live"))
  (emacs-hypervisor--record :send message)
  (process-send-string
   emacs-hypervisor--process
   (concat (emacs-hypervisor--sexp-string message) "\n")))

(defun emacs-hypervisor--rpc-message-p (message)
  (and (consp message)
       (eq (car message) :rpc)
       (eq (plist-get (cdr message) :protocol) emacs-hypervisor-protocol-name)
       (= (plist-get (cdr message) :version) emacs-hypervisor-protocol-version)))

(defun emacs-hypervisor--rpc-kind (message)
  (plist-get (cdr message) :kind))

(defun emacs-hypervisor--rpc-id (message)
  (plist-get (cdr message) :id))

(defun emacs-hypervisor--rpc-op (message)
  (plist-get (cdr message) :op))

(defun emacs-hypervisor--rpc-topic (message)
  (plist-get (cdr message) :topic))

(defun emacs-hypervisor--rpc-payload (message)
  (plist-get (cdr message) :payload))

(defun emacs-hypervisor--make-rpc-response (id payload)
  (list :rpc
        :protocol emacs-hypervisor-protocol-name
        :version emacs-hypervisor-protocol-version
        :kind :response
        :id id
        :ok t
        :payload payload))

(defun emacs-hypervisor--make-rpc-error-response (id error)
  (list :rpc
        :protocol emacs-hypervisor-protocol-name
        :version emacs-hypervisor-protocol-version
        :kind :response
        :id id
        :ok nil
        :error error))

(defun emacs-hypervisor--make-rpc-event (topic payload)
  (list :rpc
        :protocol emacs-hypervisor-protocol-name
        :version emacs-hypervisor-protocol-version
        :kind :event
        :topic topic
        :payload payload))

(defun emacs-hypervisor-send-response (id payload)
  (emacs-hypervisor-send
   (emacs-hypervisor--make-rpc-response id payload)))

(defun emacs-hypervisor-send-error-response (id error)
  (emacs-hypervisor-send
   (emacs-hypervisor--make-rpc-error-response id error)))

(defun emacs-hypervisor-send-event (topic payload)
  (emacs-hypervisor-send
   (emacs-hypervisor--make-rpc-event topic payload)))

(defun emacs-hypervisor--rpc-metric-details (id op payload)
  (append
   (list :op op
         :request-id id)
   (when (eq op :eval)
     (list
      :phase (plist-get payload :phase)
      :metric-kind (or (plist-get payload :metric-kind) :eval)
      :item-name (or (plist-get payload :item-name)
                     (plist-get payload :metric-name))))))

(defun emacs-hypervisor--record-rpc-metric (id op payload started-at)
  (when (emacs-hypervisor-benchmark-enabled-p)
    (apply
     #'emacs-hypervisor-report-note-metric
     :emacs-rpc
     (or (and (eq op :eval)
              (plist-get payload :metric-name))
         op)
     (* 1000.0 (- (float-time) started-at))
     (emacs-hypervisor--rpc-metric-details id op payload))))

(defun emacs-hypervisor--dispatch-rpc-eval (id form)
  (condition-case err
      (let ((value (eval form)))
        (emacs-hypervisor-send-response id value))
    (error
     (emacs-hypervisor-send-error-response
      id
      (concat
       (format "%S" err)
       "\n"
       (with-output-to-string
         (backtrace)))))))

(defun emacs-hypervisor--dispatch-rpc-request (message)
  (let* ((id (emacs-hypervisor--rpc-id message))
         (op (emacs-hypervisor--rpc-op message))
         (payload (emacs-hypervisor--rpc-payload message))
         (started-at (float-time))
         handled)
    (setq handled
          (pcase op
            (:hello
             (setq emacs-hypervisor--hello-message message)
             (setq emacs-hypervisor--state :running)
             (emacs-hypervisor-send-response
              id
              (list :protocol emacs-hypervisor-protocol-name
                    :version emacs-hypervisor-protocol-version
                    :mode :session-scoped-subprocess
                    :transport :s-expression))
             t)
            (:boot-context
             (if (functionp emacs-hypervisor-context-function)
                 (emacs-hypervisor-send-response
                  id
                  (or (funcall emacs-hypervisor-context-function) nil))
               (emacs-hypervisor-send-response id nil))
             t)
            (:session-data
             (if (functionp emacs-hypervisor-session-data-function)
                 (let* ((fields (plist-get payload :fields))
                        (session-data
                         (funcall emacs-hypervisor-session-data-function fields)))
                   (emacs-hypervisor-send-response id session-data))
               (emacs-hypervisor-send-response id nil))
             t)
            (:eval
             (emacs-hypervisor--dispatch-rpc-eval id (plist-get payload :form))
             t)
            (_
             (emacs-hypervisor-send-error-response
              id
              (format "Unknown sexp-rpc op: %S" op))
             t)))
    (emacs-hypervisor--record-rpc-metric id op payload started-at)
    handled))

(defun emacs-hypervisor--dispatch-rpc-event (message)
  (let* ((topic (emacs-hypervisor--rpc-topic message))
         (payload (emacs-hypervisor--rpc-payload message)))
    (pcase topic
      (:plan
       (push (append '(:plan) payload) emacs-hypervisor--plan-messages)
       (emacs-hypervisor-report-note-plan)
       t)
      (:progress
       (setq emacs-hypervisor--last-progress-message
             (append '(:progress) payload))
       (push (append '(:progress) payload) emacs-hypervisor--progress-messages)
       (emacs-hypervisor-report-note-progress)
       t)
      (:log
       (setq emacs-hypervisor--last-log-message
             (append '(:log) payload))
       (push (append '(:log) payload) emacs-hypervisor--log-messages)
       (emacs-hypervisor-report-note-log)
       t)
      (:report
       (push (append '(:report) payload) emacs-hypervisor--report-messages)
       (emacs-hypervisor-report-note-report)
       t)
      (:metric
       (when (emacs-hypervisor-benchmark-enabled-p)
         (emacs-hypervisor-report-note-metric
          (or (plist-get payload :source) :elle)
          (or (plist-get payload :name) :metric)
          (or (plist-get payload :duration-ms) 0.0)
          :phase (plist-get payload :phase)
          :metric-kind (plist-get payload :metric-kind)
          :item-name (or (plist-get payload :item-name)
                         (plist-get payload :detail))))
       t)
      (:shutdown
       (setq emacs-hypervisor--shutdown-reason
             (plist-get payload :reason))
       (setq emacs-hypervisor--state :completed)
       (setq emacs-hypervisor--completed t)
       (emacs-hypervisor-report-session-finished)
       t)
      (_ nil))))

(defun emacs-hypervisor--dispatch (message)
  (emacs-hypervisor--record :recv message)
  (unless (emacs-hypervisor--rpc-message-p message)
    (error "Unsupported non-sexp-rpc message: %S" message))
  (pcase (emacs-hypervisor--rpc-kind message)
    (:request
     (emacs-hypervisor--dispatch-rpc-request message))
    (:event
     (or (emacs-hypervisor--dispatch-rpc-event message)
         (and (functionp emacs-hypervisor--runtime-dispatch-function)
              (funcall emacs-hypervisor--runtime-dispatch-function message))
         nil))
    (_ nil)))

(defun emacs-hypervisor-sexp-rpc-filter (proc chunk)
  "Read newline-delimited S-expression RPC messages from PROC CHUNK."
  (let ((buffer (process-buffer proc)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert chunk)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (skip-chars-forward "[:space:]")
            (let ((message (read (current-buffer))))
              (delete-region (point-min) (point))
              (save-current-buffer
                (emacs-hypervisor--dispatch message))
              (goto-char (point-min))))
        (end-of-file nil)))))

(provide 'emacs-hypervisor-sexp-rpc)
