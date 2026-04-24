## Generic emitted loader for static Elisp modules.

(defn emacs-hypervisor-runtime-forms-module-loader-module []
  (defn module-path [module-spec]
    (if (string? module-spec)
      module-spec
      (get module-spec :path)))

  (defn module-source [module-spec]
    (if (string? module-spec)
      (slurp module-spec)
      (let [embedded-source (get module-spec :source)
            path (get module-spec :path)]
        (or embedded-source
            (and path (slurp path))))))

  (defn module-forms [module-spec]
    (and (not (string? module-spec))
         (get module-spec :forms)))

  (defn load-module-form [module-spec ready-marker]
    (let [path (or (module-path module-spec) "<embedded-module>")
          forms (module-forms module-spec)
          source (and (nil? forms) (module-source module-spec))]
      (cond
       (forms
        (let [module-forms-literal (list 'quote forms)]
          `((let ((emacs-hypervisor-source-path ,path)
                  (emacs-hypervisor-module-forms ,module-forms-literal))
              (with-temp-buffer
                (setq-local lexical-binding t)
                (setq-local load-file-name emacs-hypervisor-source-path)
                (setq-local buffer-file-name emacs-hypervisor-source-path)
                (dolist (emacs-hypervisor-form emacs-hypervisor-module-forms)
                  (prin1 emacs-hypervisor-form (current-buffer))
                  (insert "
"))
                (set-buffer-modified-p nil)
                (goto-char (point-min))
                (eval-buffer)
                (set-buffer-modified-p nil)
                (setq-local buffer-file-name nil)
                (setq-local load-file-name nil)
                ,ready-marker)))))

       (source
        `((let ((emacs-hypervisor-source-path ,path)
                (emacs-hypervisor-source-text ,source))
            (with-temp-buffer
              (setq-local lexical-binding t)
              (setq-local load-file-name emacs-hypervisor-source-path)
              (setq-local buffer-file-name emacs-hypervisor-source-path)
              (insert emacs-hypervisor-source-text)
              (set-buffer-modified-p nil)
              (goto-char (point-min))
              (eval-buffer)
              (set-buffer-modified-p nil)
              (setq-local buffer-file-name nil)
              (setq-local load-file-name nil)
              ,ready-marker))))

       (true
        (assert false
                (string "expected module forms or source for " path))))))

  {:load-module-form load-module-form})
