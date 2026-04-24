## Generic emitted loader for source-of-truth Elisp helper files.

(defn emacs-hypervisor-runtime-forms-source-loader-module []
  (defn source-path [source-spec]
    (if (string? source-spec)
      source-spec
      (get source-spec :path)))

  (defn source-text [source-spec]
    (if (string? source-spec)
      (slurp source-spec)
      (let [embedded-source (get source-spec :source)
            path (get source-spec :path)]
        (or embedded-source
            (and path (slurp path))))))

  (defn load-source-form [source-spec ready-marker]
    (let [path (or (source-path source-spec) "<embedded-source>")
          source (source-text source-spec)]
      (assert source
              (string "expected source text for " path))
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
            ,ready-marker)))))

  {:load-source-form load-source-form})
