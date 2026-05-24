## Generic emitted loader for static Elisp modules.

(defn emacs-hypervisor-runtime-forms-module-loader-module []
  (defn module-path [module-spec]
    (or (get module-spec :path) "<embedded-module>"))

  (defn module-source [module-spec]
    (get module-spec :source))

  (defn module-forms [module-spec]
    (get module-spec :forms))

  (defn load-module-form [module-spec ready-marker]
    (let [path (or (module-path module-spec) "<embedded-module>")
          forms (module-forms module-spec)
          source (module-source module-spec)]
      (cond
       forms
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
                ,ready-marker))))

       source
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
              ,ready-marker)))

       true
        (assert false
                (string "expected embedded module forms or source for " path)))))

  {:load-module-form load-module-form})
