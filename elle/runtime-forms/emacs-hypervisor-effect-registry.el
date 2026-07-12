;;; emacs-hypervisor-effect-registry.el --- Runtime effect records -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defvar emacs-hypervisor-effect-registry-current nil
  "Session-scoped list of active and retracted Hypervisor effect records.")

(defvar emacs-hypervisor-effect-registry--instance-counter 0
  "Counter used to assign concrete effect instance ids.")

(defvar emacs-hypervisor-effect-registry-reset-hook nil
  "Hook run after `emacs-hypervisor-effect-registry-reset'.")

(defconst emacs-hypervisor-effect-registry--schema-version 1)

(defconst emacs-hypervisor-effect-registry--generated-prefix
  "emacs-hypervisor--generated-")

(defun emacs-hypervisor-effect-registry-reset ()
  "Reset the session-scoped effect registry."
  (setq emacs-hypervisor-effect-registry-current nil)
  (setq emacs-hypervisor-effect-registry--instance-counter 0)
  (run-hooks 'emacs-hypervisor-effect-registry-reset-hook))

(defun emacs-hypervisor-effect-registry--safe-name-component (value)
  (let* ((raw (cond
               ((symbolp value) (symbol-name value))
               ((stringp value) value)
               (t (format "%S" value))))
         (safe (replace-regexp-in-string "[^[:alnum:]_-]+" "-" raw)))
    (if (string-empty-p safe) "anonymous" safe)))

(defun emacs-hypervisor-effect-registry--hash-value (value)
  (substring
   (secure-hash
    'sha1
    (let ((print-circle t)
          (print-level nil)
          (print-length nil))
      (prin1-to-string value)))
   0
   10))

(defun emacs-hypervisor-effect-registry--next-instance-id (unit kind)
  (setq emacs-hypervisor-effect-registry--instance-counter
        (1+ emacs-hypervisor-effect-registry--instance-counter))
  (format "%s/%s/%d"
          (or unit "anonymous-unit")
          (substring (symbol-name kind) 1)
          emacs-hypervisor-effect-registry--instance-counter))

(defun emacs-hypervisor-effect-registry--effect-id
    (unit kind target function-hash)
  (format "%s/%s/%s/%s"
          (substring (symbol-name kind) 1)
          (emacs-hypervisor-effect-registry--safe-name-component unit)
          (emacs-hypervisor-effect-registry--safe-name-component target)
          function-hash))

(defun emacs-hypervisor-effect-registry--generated-function-symbol
    (unit kind target where function)
  (intern
   (format
    "%s%s-%s-%s-%s"
    emacs-hypervisor-effect-registry--generated-prefix
    (emacs-hypervisor-effect-registry--safe-name-component unit)
    (emacs-hypervisor-effect-registry--safe-name-component kind)
    (emacs-hypervisor-effect-registry--safe-name-component target)
    (emacs-hypervisor-effect-registry--hash-value
     (list :unit unit
           :kind kind
           :target target
           :where where
           :function function)))))

(defun emacs-hypervisor-effect-registry--function-symbol
    (unit kind target where function)
  "Return (SYMBOL GENERATED BODY-HASH) for FUNCTION."
  (let ((body-hash
         (emacs-hypervisor-effect-registry--hash-value function)))
    (if (symbolp function)
        (list function nil body-hash)
      (let ((symbol
             (emacs-hypervisor-effect-registry--generated-function-symbol
              unit kind target where function)))
        (fset symbol function)
        (list symbol t body-hash)))))

(defun emacs-hypervisor-effect-registry-quote-value (value)
  (list 'quote value))

(defun emacs-hypervisor-effect-registry-function-ref (symbol)
  (list 'function symbol))

(defun emacs-hypervisor-effect-registry-generated-function-cleanup-forms
    (function-symbol generated)
  (when generated
    `((when (fboundp ',function-symbol)
        (fmakunbound ',function-symbol)))))

(defun emacs-hypervisor-effect-registry--replace-effect (effect replacement)
  (let ((instance-id (plist-get effect :instance-id)))
    (setq emacs-hypervisor-effect-registry-current
          (mapcar
           (lambda (entry)
             (if (equal (plist-get entry :instance-id) instance-id)
                 replacement
               entry))
           emacs-hypervisor-effect-registry-current))))

(defun emacs-hypervisor-effect-registry-record (effect)
  "Record EFFECT and return the normalized effect record."
  (let* ((kind (plist-get effect :kind))
         (unit (plist-get effect :unit))
         (target (plist-get effect :target))
         (body-hash (or (plist-get effect :body-hash)
                        (emacs-hypervisor-effect-registry--hash-value
                         (plist-get effect :function))))
         (record
          (append
           (list
            :schema-version emacs-hypervisor-effect-registry--schema-version
            :id (or (plist-get effect :id)
                    (emacs-hypervisor-effect-registry--effect-id
                     unit kind target body-hash))
            :instance-id
            (or (plist-get effect :instance-id)
                (emacs-hypervisor-effect-registry--next-instance-id
                 unit kind))
            :body-hash body-hash
            :reversible (and (plist-get effect :retract) t)
            :persistent nil
            :status :active
            :supported t
            :reason nil)
           effect)))
    (setq emacs-hypervisor-effect-registry-current
          (append emacs-hypervisor-effect-registry-current
                  (list record)))
    record))

(defun emacs-hypervisor-effect-registry-effects-for-unit (unit)
  "Return active effect records owned by UNIT in application order."
  (cl-remove-if-not
   (lambda (effect)
     (and (equal (plist-get effect :unit) unit)
          (eq (plist-get effect :status) :active)))
   emacs-hypervisor-effect-registry-current))

(defun emacs-hypervisor-effect-registry-retract (effect)
  "Retract EFFECT and return the updated record.
A retract form may evaluate to `:diverged' to signal that the live state
changed outside Hypervisor and was deliberately left in place; the record
is then marked `:status :diverged' instead of `:retracted'.  Any other
result counts as a successful retraction."
  (let ((retract (plist-get effect :retract)))
    (unless (and (plist-get effect :reversible) retract)
      (error "Effect is not reversible: %S" effect))
    (let* ((result (eval retract t))
           (status (if (eq result :diverged) :diverged :retracted))
           (updated (plist-put (copy-sequence effect) :status status)))
      (emacs-hypervisor-effect-registry--replace-effect effect updated)
      updated)))

(defun emacs-hypervisor-effect-registry-retract-unit (unit)
  "Retract active effects for UNIT.

Return a cleanup plist compatible with
`emacs-hypervisor-effect-aware-reload-cleanup-count'."
  (let ((effects (emacs-hypervisor-effect-registry-effects-for-unit unit))
        cleaned
        diverged
        unsupported
        failures)
    (dolist (effect (reverse effects))
      (if (and (plist-get effect :supported)
               (plist-get effect :reversible)
               (plist-get effect :retract))
          (condition-case err
              (let ((updated (emacs-hypervisor-effect-registry-retract
                              effect)))
                (if (eq (plist-get updated :status) :diverged)
                    (push updated diverged)
                  (push updated cleaned)))
            (error
             (push (append effect
                           (list :error (format "%S" err)))
                   failures)))
        (push effect unsupported)))
    (list :effects effects
          :cleaned (nreverse cleaned)
          :diverged (nreverse diverged)
          :unsupported (nreverse unsupported)
          :failed (nreverse failures))))

(cl-defun emacs-hypervisor-effect-registry-install-function-effect
    (&key unit kind target where function source install apply retract
          cleanup-form metadata)
  "Install FUNCTION as a named effect and record its lifecycle forms."
  (cl-destructuring-bind (function-symbol generated body-hash)
      (emacs-hypervisor-effect-registry--function-symbol
       unit kind target where function)
    (condition-case err
        (progn
          (funcall install function-symbol)
          (emacs-hypervisor-effect-registry-record
           (list
            :unit unit
            :kind kind
            :target target
            :function function-symbol
            :source source
            :apply (funcall apply function-symbol)
            :retract (funcall retract function-symbol generated)
            :cleanup-form
            (and cleanup-form
                 (funcall cleanup-form function-symbol))
            :body-hash body-hash
            :metadata (append metadata
                              (list :generated-function generated)))))
      (error
       (when (and generated (fboundp function-symbol))
         (fmakunbound function-symbol))
       (signal (car err) (cdr err))))
    function-symbol))

(provide 'emacs-hypervisor-effect-registry)
