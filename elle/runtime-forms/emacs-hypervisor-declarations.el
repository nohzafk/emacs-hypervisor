;;; emacs-hypervisor-declarations.el --- Minimal declaration registry -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-aware-reload)

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

(defun emacs-hypervisor--elle-incompatible-symbol-p (value)
  "Return non-nil if VALUE is a symbol whose printed name elle can't tokenize.

Currently covers:

- digit-prefix arithmetic ops `1+' and `1-', which elle's reader splits into
  an integer and an operator
- the symbol `{}', which elle's reader treats as an empty struct literal"
  (and (symbolp value)
       (let ((name (symbol-name value)))
         (or (equal name "1+")
             (equal name "1-")
             (equal name "{}")))))

(defun emacs-hypervisor--proper-list-p (value)
  "Return non-nil when VALUE is a nil-terminated proper list."
  (let ((tail value))
    (while (consp tail)
      (setq tail (cdr tail)))
    (null tail)))

(defun emacs-hypervisor--quoted-data-form (datum)
  "Return an elle-readable form that evaluates to DATUM.

This is intentionally data-lowering, not code canonicalization: quoted data
such as `(1+ 2)' must remain a list containing the symbol `1+', not become
`(+ 2 1)'."
  (cond
   ((null datum) nil)
   ((symbolp datum)
    (if (emacs-hypervisor--elle-incompatible-symbol-p datum)
        (list (intern "intern") (symbol-name datum))
      (list (intern "quote") datum)))
   ((consp datum)
    (if (emacs-hypervisor--proper-list-p datum)
        (cons (intern "list")
              (mapcar #'emacs-hypervisor--quoted-data-form datum))
      (list (intern "cons")
            (emacs-hypervisor--quoted-data-form (car datum))
            (emacs-hypervisor--quoted-data-form (cdr datum)))))
   ((vectorp datum)
    (cons (intern "vector")
          (mapcar #'emacs-hypervisor--quoted-data-form
                  (append datum nil))))
   (t datum)))

(defun emacs-hypervisor--canonicalize-body-form (form)
  "Rewrite FORM so its printed representation is elle-readable.

Expands captured backquote forms structurally, rewrites `(1+ X)' to
`(+ X 1)' and `(1- X)' to `(- X 1)' structurally.
Quoted data is lowered with data constructors so reader-hostile symbols
remain literal data instead of being treated as code.
Signals an error if reader-hostile symbols appear bare outside supported
code or quoted-data positions."
  (cond
   ((vectorp form)
    (vconcat
     (mapcar #'emacs-hypervisor--canonicalize-body-form form)))
   ((consp form)
    (let* ((head (car form))
           (head-name (and (symbolp head) (symbol-name head))))
      (cond
       ((equal head-name "`")
        (emacs-hypervisor--canonicalize-body-form (macroexpand form)))
       ((member head-name '("," ",@"))
        (error "config-unit!: bare `%s' is not supported outside backquote"
               head))
       ((and (equal head-name "quote")
             (consp (cdr form))
             (null (cddr form)))
        (emacs-hypervisor--quoted-data-form (cadr form)))
       ((and (equal head-name "function")
             (consp (cdr form))
             (null (cddr form))
             (emacs-hypervisor--elle-incompatible-symbol-p (cadr form)))
        (list (intern "symbol-function")
              (list (intern "intern") (symbol-name (cadr form)))))
       ((and (equal head-name "1+")
             (consp (cdr form))
             (null (cddr form)))
        (list (intern "+")
              (emacs-hypervisor--canonicalize-body-form (cadr form))
              1))
       ((and (equal head-name "1-")
             (consp (cdr form))
             (null (cddr form)))
        (list (intern "-")
              (emacs-hypervisor--canonicalize-body-form (cadr form))
              1))
       (t (cons (emacs-hypervisor--canonicalize-body-form (car form))
                (emacs-hypervisor--canonicalize-body-form (cdr form)))))))
   ((emacs-hypervisor--elle-incompatible-symbol-p form)
    (error "config-unit!: bare `%s' is not supported outside call position"
           form))
   (t form)))

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
  "Register an eager Hypervisor config unit.

NAME is the unit name. ARGS is a plist ending with `:config' followed by the
body forms to run.

Recognized plist keys before `:config':

` :requires'
  Optional list of features to preload before running the body. This is not
  mandatory. Use it only when the body truly needs those packages already
  loaded, for example when it touches package-local maps, variables, macros,
  or non-autoloaded functions.

  Omit `:requires' when the unit can run eagerly using only autoloaded
  commands, hook registration, global keybindings, or pre-load-safe variable
  setup. Omitting it keeps the unit eager while avoiding unnecessary package
  loads during boot.

` :after'
  Optional list of other config units that must complete first.

` :env'
  Optional list of environment variable names required by the unit.

` :executable'
  Optional list of executables required by the unit.

Every `config-unit!' remains part of eager startup. `:requires' controls
feature preloading, not whether the unit itself is lazy or deferred."
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
           (body-form
            (emacs-hypervisor-effect-aware-reload-normalize-body
             unit-name
             `(progn ,@body t))))
      `(push
        (list
         :name ,unit-name
         :requires ',requires
         :after ',after
         :env ',env
         :executable ',executable
         :body ',body-form)
        emacs-hypervisor-config-units))))

(defun emacs-hypervisor-export-packages ()
  (nreverse (copy-sequence emacs-hypervisor-packages)))

(defun emacs-hypervisor--canonicalize-unit (entry)
  "Return ENTRY with its `:body' rewritten for elle-reader compatibility."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :body
               (emacs-hypervisor--canonicalize-body-form
                (plist-get entry :body)))))

(defun emacs-hypervisor-export-config-units ()
  (mapcar #'emacs-hypervisor--canonicalize-unit
          (nreverse (copy-sequence emacs-hypervisor-config-units))))

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
