;;; emacs-hypervisor-config-loader.el --- Config loading helpers -*- lexical-binding: t; -*-

(require 'emacs-hypervisor-config-paths)
(require 'emacs-hypervisor-declarations)

;; `ob-tangle' is only loaded inside the tangle function to keep org out of
;; non-literate startups.  Forward-declare its special variables so the
;; let-bindings below stay dynamic under standalone byte-compilation.
(defvar org-babel-default-header-args)
(defvar org-babel-tangle-comment-format-beg)
(defvar org-babel-tangle-comment-format-end)
(declare-function org-babel-merge-params "ob-core")
(declare-function org-babel-tangle-file "ob-tangle")

(defconst emacs-hypervisor--config-org-elisp-lang-regexp
  (rx string-start (or "elisp" "emacs-lisp") string-end)
  "Org Babel language tags accepted for Emacs Lisp config blocks.")

(defconst emacs-hypervisor--tangle-comment-format-beg
  "hypervisor-block-begin file:%file line:%start-line name:%source-name"
  "Tangle comment carrying exact org provenance for each block.
`%file' and `%start-line' locate the block body in the org file;
`%source-name' is the heading-derived block label.")

(defconst emacs-hypervisor--tangle-comment-format-end
  "hypervisor-block-end"
  "Closing tangle comment marking the end of a mapped block.")

(defconst emacs-hypervisor--tangle-block-begin-regexp
  "^;;+ hypervisor-block-begin file:\\(.*\\) line:\\([0-9]+\\) name:\\(.*\\)$"
  "Regexp matching the begin marker emitted into the tangled file.")

(defun emacs-hypervisor--tangle-config-org-file (config-org-file)
  "Tangle CONFIG-ORG-FILE and return the generated load target.
Injects `:comments link' so each tangled block carries an org provenance
marker; blocks that set `:comments' explicitly keep their own setting."
  (let ((tangled-file
         (expand-file-name
          ".config.tangled.el"
          (file-name-directory config-org-file))))
    (require 'ob-tangle)
    (let ((org-babel-default-header-args
           (org-babel-merge-params org-babel-default-header-args
                                   '((:comments . "link"))))
          (org-babel-tangle-comment-format-beg
           emacs-hypervisor--tangle-comment-format-beg)
          (org-babel-tangle-comment-format-end
           emacs-hypervisor--tangle-comment-format-end))
      (org-babel-tangle-file
       config-org-file tangled-file
       emacs-hypervisor--config-org-elisp-lang-regexp))
    tangled-file))

(defun emacs-hypervisor--source-name-heading (name)
  "Return the heading label from a tangle marker NAME.
Unnamed blocks tangle as \"Heading:N\"; named blocks use the block name."
  (if (string-match "\\`\\(.*\\):[0-9]+\\'" name)
      (match-string 1 name)
    name))

(defun emacs-hypervisor--source-map-markers (&optional base-directory)
  "Collect block provenance markers from the current (tangled) buffer.
Marker file paths are relative to the tangled file; BASE-DIRECTORY expands
them.  Returns a list of (TANGLED-LINE FILE ORG-LINE HEADING), ascending."
  (save-excursion
    (goto-char (point-min))
    (let (markers)
      (while (re-search-forward
              emacs-hypervisor--tangle-block-begin-regexp nil t)
        (push (list (line-number-at-pos (match-beginning 0))
                    (expand-file-name (match-string-no-properties 1)
                                      base-directory)
                    (string-to-number (match-string-no-properties 2))
                    (emacs-hypervisor--source-name-heading
                     (match-string-no-properties 3)))
              markers))
      (nreverse markers))))

(defun emacs-hypervisor--source-for-line (markers line fallback-file)
  "Resolve the source plist for tangled LINE using MARKERS.
Falls back to FALLBACK-FILE coordinates when LINE precedes every marker,
as in a plain `config.el' or an unmapped tangled region."
  (let (best)
    (dolist (marker markers)
      (when (< (car marker) line)
        (setq best marker)))
    (if best
        (pcase-let ((`(,marker-line ,file ,org-line ,heading) best))
          (list :file file
                :heading heading
                :line (+ org-line (- line marker-line 1))
                :tangled-line line))
      (list :file fallback-file :line line))))

(defun emacs-hypervisor--buffer-lexical-binding-p ()
  "Return non-nil when the current buffer declares lexical binding.
Mirrors the file-variable cookie `load-file' would honor."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t))
      (and (re-search-forward "-\\*-.*lexical-binding: *t.*-\\*-"
                              (line-end-position) t)
           t))))

(defun emacs-hypervisor--load-with-source-map (load-target)
  "Load LOAD-TARGET form by form, binding source provenance around each.
Declarations evaluated during the load capture their `config.org' (or
`config.el') location through `emacs-hypervisor--current-source'."
  (with-temp-buffer
    (insert-file-contents load-target)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (let* ((target-directory (file-name-directory load-target))
           (markers (emacs-hypervisor--source-map-markers target-directory))
           (lexical (emacs-hypervisor--buffer-lexical-binding-p))
           (load-file-name load-target)
           (default-directory target-directory))
      (goto-char (point-min))
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (let* ((line (line-number-at-pos (point)))
               (emacs-hypervisor--current-source
                (emacs-hypervisor--source-for-line markers line load-target))
               (form (read (current-buffer))))
          (eval form lexical)))))
  load-target)

(defun emacs-hypervisor-config-loader-prepare-load-target
    (&optional config-file config-org-file)
  "Return the config file to load, tangling CONFIG-ORG-FILE when present."
  (let ((config-file (or config-file (emacs-hypervisor--config-file)))
        (config-org-file
         (or config-org-file
             (let ((path (emacs-hypervisor--config-org-file)))
               (and (file-exists-p path) path)))))
    (if config-org-file
        (emacs-hypervisor--tangle-config-org-file config-org-file)
      config-file)))

(defun emacs-hypervisor-tangle-config ()
  "Tangle repo-root config.org into the shadow tangled file."
  (interactive)
  (let ((config-org-file (emacs-hypervisor--config-org-file)))
    (unless (and config-org-file (file-exists-p config-org-file))
      (user-error "No config.org at %s" config-org-file))
    (emacs-hypervisor--tangle-config-org-file config-org-file)))

(defun emacs-hypervisor-load-startup-config (&optional config-file config-org-file)
  "Reset declarations and load CONFIG-FILE or tangled CONFIG-ORG-FILE.

When called without arguments, use the configured Hypervisor paths inside
Emacs. This keeps boot-context paths out of the host-to-Emacs eval payload."
  (let ((load-target
         (emacs-hypervisor-config-loader-prepare-load-target
          config-file
          config-org-file)))
    (emacs-hypervisor-reset-declarations)
    (emacs-hypervisor--load-with-source-map load-target)
    :ok))

(provide 'emacs-hypervisor-config-loader)
