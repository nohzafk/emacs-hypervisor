;;; emacs-hypervisor-lint.el --- Structural config lint -*- lexical-binding: t; -*-

;;; Commentary:
;; Conservative pattern matching over exported declarations, used by the
;; `check' subcommand.  No body is executed.  Findings are plists of
;; (:unit NAME :rule RULE :severity SEV :message MSG :form-string STR
;;  :source SOURCE); forms cross the wire as strings so reader-hostile
;; symbols never reach Elle's reader.

(require 'cl-lib)
(require 'emacs-hypervisor-declarations)

(defun emacs-hypervisor-lint--finding (unit rule severity message form source)
  (list :unit unit
        :rule rule
        :severity severity
        :message message
        :form-string (and form (format "%S" form))
        :source source))

(defun emacs-hypervisor-lint--minor-mode-setq-p (form)
  "Match (setq SOMETHING-mode t), a likely (SOMETHING-mode 1) mistake."
  (and (eq (car-safe form) 'setq)
       (= (length form) 3)
       (symbolp (nth 1 form))
       (string-suffix-p "-mode" (symbol-name (nth 1 form)))
       (eq (nth 2 form) t)))

(defun emacs-hypervisor-lint--anonymous-function-p (value)
  (or (eq (car-safe value) 'lambda)
      (and (memq (car-safe value) '(function quote))
           (eq (car-safe (cadr value)) 'lambda))))

(defun emacs-hypervisor-lint--form-rule (form)
  "Return (RULE SEVERITY MESSAGE) when FORM matches a lint pattern.
Raw `add-hook'/`advice-add'/keybinding calls only survive in the exported
body when the effect rewriter could not reach them (inside a lambda or an
unknown macro), so finding one means the effect is untracked on reload."
  (pcase (car-safe form)
    ('eval-after-load
     '(:eval-after-load :warning "prefer with-eval-after-load"))
    ('load-file
     '(:load-file :warning "load-file bypasses Hypervisor visibility"))
    ('global-set-key
     '(:untracked-keybinding :warning
       "keybinding in an untracked position; it will not be cleaned on reload"))
    ('add-hook
     (when (emacs-hypervisor-lint--anonymous-function-p (nth 2 form))
       '(:untracked-anonymous-hook :warning
         "anonymous hook in an untracked position; it will not be cleaned on reload")))
    ('advice-add
     (when (emacs-hypervisor-lint--anonymous-function-p (nth 3 form))
       '(:untracked-anonymous-advice :warning
         "anonymous advice in an untracked position; it will not be cleaned on reload")))
    ('setq
     (when (emacs-hypervisor-lint--minor-mode-setq-p form)
       (list :minor-mode-setq :warning
             (format "did you mean (%s 1)?" (nth 1 form)))))
    (_ nil)))

(defun emacs-hypervisor-lint--walk-body (unit body source collect)
  "Walk BODY collecting findings via COLLECT.  Quoted data is skipped."
  (let ((worklist (list body)))
    (while worklist
      (let ((form (pop worklist)))
        (when (consp form)
          (unless (eq (car-safe form) 'quote)
            (pcase (emacs-hypervisor-lint--form-rule form)
              (`(,rule ,severity ,message)
               (funcall collect
                        (emacs-hypervisor-lint--finding
                         unit rule severity message form source))))
            (dolist (child form)
              (when (consp child)
                (push child worklist)))))))))

(defun emacs-hypervisor-lint--duplicate-names (entries kind)
  "Return :error findings for names declared more than once in ENTRIES."
  (let ((seen (make-hash-table :test #'equal))
        findings)
    (dolist (entry entries)
      (let ((name (plist-get entry :name)))
        (puthash name (1+ (gethash name seen 0)) seen)))
    (dolist (entry entries)
      (let* ((name (plist-get entry :name))
             (count (gethash name seen 0)))
        (when (> count 1)
          ;; Report once per name, on its first occurrence.
          (puthash name 0 seen)
          (push (emacs-hypervisor-lint--finding
                 name :duplicate-name :error
                 (format "%s %s is declared %d times" kind name count)
                 nil (plist-get entry :source))
                findings))))
    (nreverse findings)))

(defun emacs-hypervisor-lint-exported-declarations ()
  "Lint all exported declarations.  Returns a list of finding plists."
  (let* ((packages (emacs-hypervisor-export-packages))
         ;; Lint the raw registered entries in declaration order, not the
         ;; canonicalized export: lint output never crosses to Elle as code.
         (units (reverse emacs-hypervisor-config-units))
         (findings
          (append
           (emacs-hypervisor-lint--duplicate-names packages "package")
           (emacs-hypervisor-lint--duplicate-names units "config-unit"))))
    (dolist (entry units)
      (let ((collected nil))
        (emacs-hypervisor-lint--walk-body
         (plist-get entry :name)
         (plist-get entry :body)
         (plist-get entry :source)
         (lambda (finding) (push finding collected)))
        (setq findings (append findings (nreverse collected)))))
    findings))

(provide 'emacs-hypervisor-lint)
