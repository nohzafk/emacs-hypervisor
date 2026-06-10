;;; emacs-hypervisor-sexp-rpc.el --- S-expression RPC transport -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-session-state)
(require 'emacs-hypervisor-events)

(defconst emacs-hypervisor-protocol-name :sexp-rpc)
(defconst emacs-hypervisor-protocol-version 1)

(defvar emacs-hypervisor--process nil)
(defvar emacs-hypervisor--hello-message nil)
(defvar emacs-hypervisor--state :idle)
(defvar emacs-hypervisor--next-request-id 100000)
(defvar emacs-hypervisor--pending-responses nil)
(defvar emacs-hypervisor-context-function nil)
(defvar emacs-hypervisor-session-data-function nil)

(declare-function emacs-hypervisor-details-buffer "emacs-hypervisor-session-state")
(declare-function emacs-hypervisor--record "emacs-hypervisor-session-state")
(declare-function emacs-hypervisor-events-handle "emacs-hypervisor-events")
(declare-function emacs-hypervisor-events-record-rpc-metric "emacs-hypervisor-events")
(declare-function emacs-hypervisor-live-p "emacs-hypervisor-session-state")

(defun emacs-hypervisor--sexp-string (value)
  "Serialize VALUE as a reader-compatible single-line S-expression.

`print-quoted' is bound to nil so that `(quote x)' and `(function x)'
are emitted in their explicit list forms rather than the reader
shortcuts `'x' and `#'x', which elle's reader does not accept."
  (let ((print-level nil)
        (print-length nil)
        (print-escape-newlines t)
        (print-escape-control-characters t)
        (print-circle nil)
        (print-quoted nil))
    (prin1-to-string value)))

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

(defun emacs-hypervisor--make-rpc-request (id op payload)
  (list :rpc
        :protocol emacs-hypervisor-protocol-name
        :version emacs-hypervisor-protocol-version
        :kind :request
        :id id
        :op op
        :payload payload))

(defun emacs-hypervisor-send-request (op payload)
  "Send an Emacs-initiated request with OP and PAYLOAD.
Return the request id."
  (let ((id emacs-hypervisor--next-request-id))
    (setq emacs-hypervisor--next-request-id
          (1+ emacs-hypervisor--next-request-id))
    (emacs-hypervisor-send
     (emacs-hypervisor--make-rpc-request id op payload))
    id))

(defun emacs-hypervisor--dispatch-rpc-eval (id form)
  (condition-case err
      (let ((value
             (with-current-buffer (emacs-hypervisor-details-buffer)
               (let ((standard-output (current-buffer)))
                 (eval form)))))
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
    (emacs-hypervisor-events-record-rpc-metric id op payload started-at)
    handled))

(defun emacs-hypervisor--dispatch-rpc-event (message)
  (let* ((topic (emacs-hypervisor--rpc-topic message))
         (payload (emacs-hypervisor--rpc-payload message)))
    (emacs-hypervisor-events-handle topic payload)))

(defun emacs-hypervisor--dispatch-rpc-response (message)
  (let ((id (emacs-hypervisor--rpc-id message)))
    (setq emacs-hypervisor--pending-responses
          (plist-put emacs-hypervisor--pending-responses id message))
    t))

(defun emacs-hypervisor--pop-pending-response (id)
  (let ((response (plist-get emacs-hypervisor--pending-responses id)))
    (when response
      (cl-remf emacs-hypervisor--pending-responses id))
    response))

(defun emacs-hypervisor-await-response (id &optional timeout)
  "Wait for an Emacs-initiated request response with ID.
Signal an error when TIMEOUT seconds elapse."
  (let ((deadline (and timeout (+ (float-time) timeout)))
        response)
    (while (and (not (setq response (emacs-hypervisor--pop-pending-response id)))
                (emacs-hypervisor-live-p)
                (or (null deadline) (< (float-time) deadline)))
      (accept-process-output emacs-hypervisor--process 0.05))
    (cond
     (response response)
     ((not (emacs-hypervisor-live-p))
      (error "Hypervisor process is not live"))
     (t
      (error "Timed out waiting for Hypervisor response %s" id)))))

(defun emacs-hypervisor-request (op payload &optional timeout)
  "Send OP and PAYLOAD to Elle, then wait for the response payload."
  (let* ((id (emacs-hypervisor-send-request op payload))
         (response (emacs-hypervisor-await-response id timeout)))
    (if (plist-get (cdr response) :ok)
        (plist-get (cdr response) :payload)
      (error "%s" (or (plist-get (cdr response) :error)
                      "Hypervisor request failed")))))

(defun emacs-hypervisor-extension-call (extension method args &optional timeout)
  "Call Elle EXTENSION METHOD with ARGS over `sexp-rpc'."
  (emacs-hypervisor-request
   :extension-call
   (list :extension extension :method method :args args)
   timeout))

(defun emacs-hypervisor--dispatch (message)
  (emacs-hypervisor--record :recv message)
  (unless (emacs-hypervisor--rpc-message-p message)
    (error "Unsupported non-sexp-rpc message: %S" message))
  (pcase (emacs-hypervisor--rpc-kind message)
    (:request (emacs-hypervisor--dispatch-rpc-request message))
    (:event (emacs-hypervisor--dispatch-rpc-event message))
    (:response (emacs-hypervisor--dispatch-rpc-response message))
    (_ nil)))

(defun emacs-hypervisor--consume-input ()
  (let ((input-buffer (current-buffer))
        value
        done)
    (while (not done)
      (goto-char (point-min))
      (condition-case err
          (progn
            (setq value (read (current-buffer)))
            (set-buffer input-buffer)
            (skip-chars-forward " \t\r\n")
            ;; Dispatch can run `accept-process-output', so remove the complete
            ;; message first to prevent reentrant filters from re-reading it.
            (delete-region (point-min) (point))
            (emacs-hypervisor--dispatch value)
            (set-buffer input-buffer))
        (end-of-file
         (set-buffer input-buffer)
         (setq done t))
        (error
         (set-buffer input-buffer)
         (erase-buffer)
         (signal (car err) (cdr err)))))))

(defun emacs-hypervisor-sexp-rpc-filter (_proc output)
  (with-current-buffer (get-buffer-create emacs-hypervisor--buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert output)
      (emacs-hypervisor--consume-input))))

(provide 'emacs-hypervisor-sexp-rpc)
