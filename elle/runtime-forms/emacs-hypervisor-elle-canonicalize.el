;;; emacs-hypervisor-elle-canonicalize.el --- Elle-reader compatibility -*- lexical-binding: t; -*-

;;; Commentary:
;; Rewrite Emacs Lisp forms so their printed representation is readable by
;; Elle.  Used by `config-unit!` exports to cross the Emacs/Elle boundary
;; without losing semantics for forms that contain `1+`, `1-`, `{}`, or
;; reader-hostile symbols in quoted data.

(defun emacs-hypervisor--elle-incompatible-symbol-p (value)
  "Return non-nil if VALUE is a symbol whose printed name elle can't tokenize.

Two classes, tested differently because they print differently:

- Named cases, which Emacs prints with no escape at all: the digit-prefix
  arithmetic ops `1+' and `1-', which elle's reader splits into an integer and
  an operator, and `{}', which elle's reader treats as an empty struct literal.
  Nothing in the printed form marks these, so they have to be listed.

- Any symbol Emacs itself can only print with a backslash escape.  Elle has no
  such escape, so it sees the bare character and applies its own reader macro
  to it.  For the reader-macro symbols \\=` , and ,@ that does not terminate:
  the host spins at 100% CPU and the startup report never leaves \"Waiting for
  package plan\".  Testing the printed form covers the whole class, rather than
  a list of characters that has to be guessed ahead of the next one.

These reach quoted-data position more often than they look like they would.
`config-unit!' captures the original source of every rewritten effect form in
`:source', so one backquote inside an `add-hook' lambda puts the symbol \\=`
into exported data even though the same backquote in code position is
macroexpanded away."
  (and (symbolp value)
       (let ((name (symbol-name value)))
         (or (equal name "1+")
             (equal name "1-")
             (equal name "{}")
             (string-match-p "\\\\" (prin1-to-string value))))))

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

(defun emacs-hypervisor--canonicalize-unit (entry)
  "Return ENTRY with its `:body' rewritten for elle-reader compatibility."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :body
               (emacs-hypervisor--canonicalize-body-form
                (plist-get entry :body)))))

(provide 'emacs-hypervisor-elle-canonicalize)
