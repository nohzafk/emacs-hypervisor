;;; emacs-hypervisor-bootstrap.el --- Minimal trusted bootstrap -*- lexical-binding: t; -*-

(require 'json)

(defconst emacs-hypervisor-protocol-name :sexp-rpc)
(defconst emacs-hypervisor-protocol-version 1)

(defvar emacs-hypervisor--buffer-name " *emacs-hypervisor*")
(defvar emacs-hypervisor--log-buffer-name "*emacs-hypervisor-log*")
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
(defvar emacs-hypervisor-context-function #'emacs-hypervisor-default-context)
(defvar emacs-hypervisor-session-data-function #'emacs-hypervisor-default-session-data)
(defvar emacs-hypervisor-process-sentinel-function nil)
(defvar emacs-hypervisor-loaded-env-file nil)
(defvar emacs-hypervisor-loaded-env-vars nil)

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
  (setq emacs-hypervisor-process-sentinel-function nil))

(defun emacs-hypervisor-log-buffer ()
  "Return the Hypervisor interactive log buffer."
  (get-buffer-create emacs-hypervisor--log-buffer-name))

(defun emacs-hypervisor-open-log-buffer ()
  "Display the Hypervisor log buffer."
  (interactive)
  (pop-to-buffer (emacs-hypervisor-log-buffer)))

(defun emacs-hypervisor--append-log-line (line)
  (with-current-buffer (emacs-hypervisor-log-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert line "\n"))))

(defun emacs-hypervisor--log (tag payload)
  (emacs-hypervisor--append-log-line
   (format "%s %-8s %s"
           (format-time-string "%H:%M:%S")
           tag
           payload)))

(defun emacs-hypervisor--record (direction payload)
  (push (cons direction payload) emacs-hypervisor--message-log)
  (emacs-hypervisor--log
   (symbol-name direction)
   (format "%S" payload)))

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
   :reports (length emacs-hypervisor--report-messages)
   :messages (length emacs-hypervisor--message-log)))

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
  (let ((id (emacs-hypervisor--rpc-id message))
        (op (emacs-hypervisor--rpc-op message))
        (payload (emacs-hypervisor--rpc-payload message)))
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
       t))))

(defun emacs-hypervisor--dispatch-rpc-event (message)
  (let* ((topic (emacs-hypervisor--rpc-topic message))
         (payload (emacs-hypervisor--rpc-payload message)))
    (pcase topic
      (:plan
       (push (append '(:plan) payload) emacs-hypervisor--plan-messages)
       t)
      (:progress
       (setq emacs-hypervisor--last-progress-message
             (append '(:progress) payload))
       (push (append '(:progress) payload) emacs-hypervisor--progress-messages)
       t)
      (:log
       (setq emacs-hypervisor--last-log-message
             (append '(:log) payload))
       (push (append '(:log) payload) emacs-hypervisor--log-messages)
       t)
      (:report
       (push (append '(:report) payload) emacs-hypervisor--report-messages)
       t)
      (:shutdown
       (setq emacs-hypervisor--shutdown-reason
             (plist-get payload :reason))
       (setq emacs-hypervisor--state :completed)
       (setq emacs-hypervisor--completed t)
       t)
      (_ nil))))

(defun emacs-hypervisor--dispatch-rpc (message)
  (pcase (emacs-hypervisor--rpc-kind message)
    (:request
     (emacs-hypervisor--dispatch-rpc-request message))
    (:event
     (or (emacs-hypervisor--dispatch-rpc-event message)
         (and (functionp emacs-hypervisor--runtime-dispatch-function)
              (funcall emacs-hypervisor--runtime-dispatch-function message))
         nil))
    (_ nil)))

(defun emacs-hypervisor--dispatch (message)
  (emacs-hypervisor--record :recv message)
  (unless (emacs-hypervisor--rpc-message-p message)
    (error "Unsupported non-sexp-rpc message: %S" message))
  (emacs-hypervisor--dispatch-rpc message))

(defun emacs-hypervisor--filter (proc chunk)
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

(defun emacs-hypervisor--normalize-process-event (event)
  (replace-regexp-in-string "[\r\n]+\\'" "" event))

(defun emacs-hypervisor--sentinel (proc event)
  (setq emacs-hypervisor--last-process-event
        (emacs-hypervisor--normalize-process-event event))
  (emacs-hypervisor--log
   "process"
   (or emacs-hypervisor--last-process-event ""))
  (unless (process-live-p proc)
    (unless emacs-hypervisor--completed
      (setq emacs-hypervisor--state :failed)
      (setq emacs-hypervisor--shutdown-reason :process-exited))
    (when (functionp emacs-hypervisor-process-sentinel-function)
      (funcall emacs-hypervisor-process-sentinel-function proc event))))

(defun emacs-hypervisor-start (command &optional process-name)
  (let ((buffer (get-buffer-create emacs-hypervisor--buffer-name)))
    (with-current-buffer buffer
      (erase-buffer))
    (with-current-buffer (emacs-hypervisor-log-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)))
    (setq emacs-hypervisor--state :starting)
    (emacs-hypervisor--log
     "start"
     (mapconcat #'shell-quote-argument command " "))
    (setq emacs-hypervisor--process
          (make-process
           :name (or process-name "emacs-hypervisor")
           :buffer buffer
           :command command
           :coding 'utf-8-unix
           :connection-type 'pipe
           :filter #'emacs-hypervisor--filter
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
