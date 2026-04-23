## Generic emitted loader for source-of-truth Elisp helper files.

(defn emacs-hypervisor-runtime-forms-source-loader-module []
  (defn load-source-form [source-path ready-marker]
    (let [source (slurp source-path)]
      `((let ((emacs-hypervisor-source-path ,source-path)
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
            ,ready-marker)))))

  {:load-source-form load-source-form})
