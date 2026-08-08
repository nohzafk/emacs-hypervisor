;;; emacs-hypervisor-config-loader.el --- Config loading helpers -*- lexical-binding: t; -*-

(require 'emacs-hypervisor-config-paths)
(require 'emacs-hypervisor-declarations)
(require 'seq)

;; `ob-tangle' is only loaded inside the tangle function to keep org out of
;; non-literate startups.  Forward-declare its special variables so the
;; let-bindings below stay dynamic under standalone byte-compilation.
(defvar org-babel-default-header-args)
(defvar org-babel-tangle-comment-format-beg)
(defvar org-babel-tangle-comment-format-end)
(defvar org-babel-tangle-use-relative-file-links)
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

(defun emacs-hypervisor--tangle-one-config-org-file (config-org-file target)
  "Tangle CONFIG-ORG-FILE to TARGET and return TARGET.
Injects `:comments link' so each tangled block carries an org provenance
marker; blocks that set `:comments' explicitly keep their own setting.

`org-babel-tangle-use-relative-file-links' is bound to nil so each marker
records an absolute source path.  Org otherwise writes the path relative
to the org file's own directory, which collapses to a bare file name and
cannot be resolved back to the right file once several sources tangle
into one shadow file."
  (require 'ob-tangle)
  (let ((org-babel-default-header-args
         (org-babel-merge-params org-babel-default-header-args
                                 '((:comments . "link"))))
        (org-babel-tangle-comment-format-beg
         emacs-hypervisor--tangle-comment-format-beg)
        (org-babel-tangle-comment-format-end
         emacs-hypervisor--tangle-comment-format-end)
        (org-babel-tangle-use-relative-file-links nil))
    (org-babel-tangle-file
     config-org-file target
     emacs-hypervisor--config-org-elisp-lang-regexp))
  target)

(defun emacs-hypervisor--tangle-config-org-files (config-org-files)
  "Tangle CONFIG-ORG-FILES in order and return the generated load target.
Each source tangles separately, so every block keeps provenance to the
file it was written in.  The per-source output is concatenated in list
order into a single shadow file, which stays the unit Hypervisor loads."
  (let* ((sources (if (listp config-org-files)
                      config-org-files
                    (list config-org-files)))
         (tangled-file (emacs-hypervisor--config-tangled-file))
         (staging (make-temp-file "emacs-hypervisor-tangle" t)))
    (unwind-protect
        (let ((parts
               (seq-map-indexed
                (lambda (source index)
                  (emacs-hypervisor--tangle-one-config-org-file
                   source
                   (expand-file-name (format "%03d.el" index) staging)))
                sources)))
          (with-temp-file tangled-file
            (dolist (part parts)
              (when (file-exists-p part)
                (insert-file-contents part)
                (goto-char (point-max))
                (unless (bolp) (insert "\n"))))))
      (delete-directory staging t))
    tangled-file))

(defun emacs-hypervisor--tangle-config-org-file (config-org-file)
  "Tangle CONFIG-ORG-FILE and return the generated load target.
CONFIG-ORG-FILE may be one path or an ordered list of paths."
  (emacs-hypervisor--tangle-config-org-files config-org-file))

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
  "Return the config file to load, tangling CONFIG-ORG-FILE when present.
CONFIG-ORG-FILE may be one path or an ordered list of paths.  When it is
omitted, the configured literate sources that exist on disk are used."
  (let* ((config-file (or config-file (emacs-hypervisor--config-file)))
         (sources
          (if config-org-file
              (if (listp config-org-file) config-org-file (list config-org-file))
            (emacs-hypervisor--existing-config-org-files))))
    (if sources
        (emacs-hypervisor--tangle-config-org-files sources)
      config-file)))

(defun emacs-hypervisor-tangle-config ()
  "Tangle the configured literate config sources into the shadow file."
  (interactive)
  (let ((sources (emacs-hypervisor--existing-config-org-files)))
    (unless sources
      (user-error "No literate config found at %s"
                  (string-join (emacs-hypervisor--config-org-files) ", ")))
    (emacs-hypervisor--tangle-config-org-files sources)))

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
