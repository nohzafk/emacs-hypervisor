;;; emacs-hypervisor-declarations.el --- Minimal declaration registry -*- lexical-binding: t; -*-

(require 'cl-lib)

(defvar emacs-hypervisor-packages nil)
(defvar emacs-hypervisor-config-units nil)
(defvar emacs-hypervisor-session-env-vars '("SHELL" "PATH"))

(defun emacs-hypervisor-reset-declarations ()
  (setq emacs-hypervisor-packages nil)
  (setq emacs-hypervisor-config-units nil))

(defun emacs-hypervisor--normalize-symbol-list (value)
  (cond
   ((null value) nil)
   ((listp value)
    (mapcar (lambda (item)
              (if (stringp item) item (symbol-name item)))
            value))
   ((or (stringp value) (symbolp value))
    (list (if (stringp value) value (symbol-name value))))
   (t nil)))

(defun emacs-hypervisor--unique-strings (values)
  (let (result)
    (dolist (value values (nreverse result))
      (when (and (stringp value)
                 (not (member value result)))
        (push value result)))))

(cl-defmacro package! (name &rest args &key repo host branch tag ref files deps local no-compilation)
  (declare (indent defun))
  (let ((pkg-name (if (stringp name) name (symbol-name name))))
    `(push
      (list
       :name ,pkg-name
       :repo ,repo
       :host ,host
       :branch ,branch
       :tag ,tag
       :ref ,ref
       :files ',files
       :deps ',(emacs-hypervisor--normalize-symbol-list deps)
       :local ,local
       :no-compilation ,no-compilation)
      emacs-hypervisor-packages)))

(defmacro config-unit! (name &rest args)
  (declare (indent defun))
  (let* ((config-index (cl-position :config args))
         (unit-name (if (stringp name) name (symbol-name name))))
    (unless config-index
      (error "config-unit! %s: Missing :config keyword" unit-name))
    (let* ((plist-pairs (seq-subseq args 0 config-index))
           (body (seq-subseq args (1+ config-index)))
           (requires (emacs-hypervisor--normalize-symbol-list
                      (plist-get plist-pairs :requires)))
           (after (emacs-hypervisor--normalize-symbol-list
                   (plist-get plist-pairs :after)))
           (env (emacs-hypervisor--normalize-symbol-list
                 (plist-get plist-pairs :env)))
           (executable (emacs-hypervisor--normalize-symbol-list
                        (plist-get plist-pairs :executable)))
           (body-string (format "%S" `(progn ,@body t))))
      `(push
        (list
         :name ,unit-name
         :requires ',requires
         :after ',after
         :env ',env
         :executable ',executable
         :body ,body-string)
        emacs-hypervisor-config-units))))

(defun emacs-hypervisor-export-packages ()
  (nreverse (copy-sequence emacs-hypervisor-packages)))

(defun emacs-hypervisor-export-config-units ()
  (nreverse (copy-sequence emacs-hypervisor-config-units)))

(defun emacs-hypervisor-export-environment-names ()
  (emacs-hypervisor--unique-strings
   (append
    emacs-hypervisor-session-env-vars
    (apply #'append
           (mapcar (lambda (unit) (copy-sequence (plist-get unit :env)))
                   emacs-hypervisor-config-units)))))

(defun emacs-hypervisor-export-environment (&optional names)
  (mapcar (lambda (name)
            (list :name name :value (getenv name)))
          (or names (emacs-hypervisor-export-environment-names))))

(defun emacs-hypervisor-export-session-data (&optional fields)
  (let ((requested (or fields '(:packages :units :env)))
        payload)
    (when (memq :packages requested)
      (setq payload
            (append payload
                    (list :packages (emacs-hypervisor-export-packages)))))
    (when (memq :units requested)
      (setq payload
            (append payload
                    (list :units (emacs-hypervisor-export-config-units)))))
    (when (memq :env requested)
      (setq payload
            (append payload
                    (list :env (emacs-hypervisor-export-environment)))))
    payload))

(provide 'emacs-hypervisor-declarations)
