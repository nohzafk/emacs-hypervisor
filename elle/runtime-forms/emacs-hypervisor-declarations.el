;;; emacs-hypervisor-declarations.el --- Minimal declaration registry -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-elle-canonicalize)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-kind-hook)
(require 'emacs-hypervisor-effect-kind-advice)
(require 'emacs-hypervisor-effect-kind-keybinding)

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

(cl-defmacro package! (name &rest args &key repo host branch tag ref deps local lisp-dir)
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
       :deps ',(emacs-hypervisor--normalize-symbol-list deps)
       :local ,local
       :lisp-dir ,lisp-dir)
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

(defun emacs-hypervisor--package-installed-p (entry)
  (let ((name (plist-get entry :name)))
    (and name
         (let ((symbol (intern name)))
	         (or (featurep symbol)
	             (and (boundp 'package-alist)
	                  (not (null (assq symbol package-alist))))
	             (and (fboundp 'package-installed-p)
	                  (not (null (package-installed-p symbol)))))))))

(defun emacs-hypervisor-export-packages ()
  (mapcar
   (lambda (entry)
     (append
      (copy-sequence entry)
      (list :installed (emacs-hypervisor--package-installed-p entry))))
   (nreverse (copy-sequence emacs-hypervisor-packages))))

(defun emacs-hypervisor-export-config-units ()
  (cl-loop for entry in (nreverse (copy-sequence emacs-hypervisor-config-units))
           for index from 0
           collect (plist-put
                    (emacs-hypervisor--canonicalize-unit entry)
                    :index
                    index)))

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
