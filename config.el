(defconst emacs-backbone-user-directory
  (file-name-as-directory
   (expand-file-name
    (or (and load-file-name (file-name-directory load-file-name))
        default-directory)))
  "Compatibility alias for Backbone-era configs loaded by Emacs Hypervisor.")

(defvar emacs-backbone-buffer-name "*emacs-hypervisor*"
  "Compatibility buffer name for Backbone-era configs.")

(let ((my-utils-file
       (expand-file-name "config/my-utils.el" emacs-backbone-user-directory)))
  (if (file-exists-p my-utils-file)
      (load-file my-utils-file)
    ;; Keep imported configs loadable before the whole local support tree moves over.
    (defun my/shorten-path-for-title (path)
      "Fallback title formatter used when `config/my-utils.el' is unavailable."
      path)))

;; (set-face-attribute 'default           nil :family "Iosevka Nerd Font Mono" :height 160)
;; (set-face-attribute 'variable-pitch    nil :family "Iosevka Nerd Font Propo")
;; (set-face-attribute 'fixed-pitch       nil :family "Iosevka Nerd Font Mono")
;; (set-face-attribute 'fixed-pitch-serif nil :family "Iosevka Nerd Font Propo")

(set-face-attribute 'default nil :family "BlexMono Nerd Font Mono" :height 140)
(set-face-attribute 'variable-pitch nil :family "Iosevka Nerd Font Propo" :height 140)
(set-face-attribute 'fixed-pitch nil :family "BlexMono Nerd Font Mono" :height 140)
(set-face-attribute 'fixed-pitch-serif nil :family "BlexMono Nerd Font Mono" :height 140)

;; use fixed-pitch-serif font for comments
(custom-set-faces
 '(font-lock-comment-face ((t (:inherit fixed-pitch-serif))))
 '(org-block ((t (:inherit fixed-pitch))))
 '(org-block-begin-line ((t (:inherit (fixed-pitch shadow)))))
 '(org-block-end-line ((t (:inherit (fixed-pitch shadow)))))
 '(org-code ((t (:inherit fixed-pitch))))
 '(org-verbatim ((t (:inherit fixed-pitch))))
 '(org-table ((t (:inherit fixed-pitch))))
 '(org-formula ((t (:inherit fixed-pitch))))
 '(org-meta-line ((t (:inherit (fixed-pitch font-lock-comment-face)))))
 '(org-checkbox ((t (:inherit fixed-pitch))))
 '(markdown-code-face ((t (:inherit fixed-pitch))))
 '(markdown-inline-code-face ((t (:inherit fixed-pitch))))
 '(markdown-pre-face ((t (:inherit fixed-pitch)))))

(package! mixed-pitch)
(config-unit! mixed-pitch
  :requires mixed-pitch
  :config
  (add-hook 'org-mode-hook #'mixed-pitch-mode)
  (add-hook 'markdown-mode-hook #'mixed-pitch-mode)
  (add-hook 'gfm-mode-hook #'mixed-pitch-mode)
  (setopt mixed-pitch-set-height nil))

(package! gruvbox-theme)
;; (package! materialized-theme :repo "xenodium/emacs-materialized-theme" :branch "main")

;; (config-unit! dynamic-theme
;;   :requires (gruvbox-theme materialized-theme)
;;   :config
;;   (defun backbone/apply-theme (appearance)
;;     "Load theme based on system APPEARANCE ('light or 'dark).
;; Also unifies UI backgrounds for a cleaner look."
;;     (mapc #'disable-theme custom-enabled-themes)
;;     (pcase appearance
;;       ('light (load-theme 'gruvbox-light-medium t))
;;       ('dark (load-theme 'materialized t))))
;;
;;   ;; Hook for dynamic theme switching when macOS appearance changes
;;   ;; Provided by system-appearance.patch in the Emacs build
;;   (add-hook 'ns-system-appearance-change-functions #'backbone/apply-theme)
;;
;;   ;; Apply theme immediately at startup based on current system appearance
;;   (backbone/apply-theme ns-system-appearance))

(config-unit! config-theme
  :requires (gruvbox-theme)
  :config
  (load-theme 'gruvbox-light-medium t))


(config-unit! unify-ui-background
  :after (config-theme)
  :config
  (defun backbone/unify-ui-background ()
    "Unify UI backgrounds to match default face background."
    (let ((bg (face-background 'default)))
      (when (and bg (not (equal bg "unspecified-bg")))
        (set-face-attribute 'fringe nil :background bg)
        (set-face-attribute 'line-number nil :background bg)
        (set-face-attribute 'line-number-current-line nil :background bg)
        (set-face-attribute 'internal-border nil :background bg)
        (set-face-attribute 'window-divider nil :foreground bg :background bg)
        (set-face-attribute 'window-divider-first-pixel nil :foreground bg :background bg)
        (set-face-attribute 'window-divider-last-pixel nil :foreground bg :background bg))))

  ;; In daemon mode, defer until first frame is created
  (if (daemonp)
      (progn
        (add-hook 'server-after-make-frame-hook #'backbone/unify-ui-background)
        ;; Also apply to current frame if it exists
        (when (framep (selected-frame))
          (backbone/unify-ui-background)))
    ;; In regular mode, apply immediately
    (backbone/unify-ui-background)))

(when (eq system-type 'darwin)
  ;; Mac OS/custom keyboard
  ;; Make control key just under the thumb, perfect way to control emacs,
  ;; respect to original keyboard shortcut design of Emacs on Symbolics's lisp
  ;; machine keyboard(http://xahlee.info/kbd/keyboard_hardware_and_key_choices.html).
  ;; See also:
  ;; http://ergoemacs.org/emacs/emacs_kb_shortcuts_pain.html
  ;; http://ergoemacs.org/emacs/modernization_meta_key.html
  ;; http://ergoemacs.org/emacs/emacs_pinky.html
  (setopt mac-command-modifier 'meta)

  ;;  make opt key do Super
  (setopt mac-option-modifier 'super)
  (keymap-set global-map "M-c" #'ns-copy-including-secondary)

  ;; MacOS specific clipboard settings
  (setopt select-enable-clipboard t
          select-enable-primary nil
          ;; ; Disable clipboard manager which can interfere
          x-select-enable-clipboard-manager nil))

(require 'server)
(unless (server-running-p)
  (server-start))

(defvar emacs-hypervisor-quit-on-last-frame-close t
  "When non-nil, closing the last GUI frame quits Emacs in this repo bootstrap.")

(defun backbone/delete-frame-or-quit (orig-fn &optional frame force)
  "Quit Emacs when FRAME is the last visible GUI frame, otherwise delete it."
  (let ((target (or frame (selected-frame))))
    (if (and emacs-hypervisor-quit-on-last-frame-close
             (not noninteractive)
             (not (daemonp))
             (display-graphic-p target)
             (<= (length (visible-frame-list)) 1))
        (save-buffers-kill-emacs)
      (funcall orig-fn frame force))))

(advice-add 'delete-frame :around #'backbone/delete-frame-or-quit)

(setq emacs-anywhere-major-mode #'markdown-mode)

;; Jinx: fast spell-checking using Enchant
(package! jinx)

;; Enable spell checking in emacs-anywhere buffers
(add-hook 'emacs-anywhere-mode-hook #'jinx-mode)
(with-eval-after-load 'emacs-anywhere
  (keymap-set emacs-anywhere-mode-map "C-;" #'jinx-correct)
  (keymap-set emacs-anywhere-mode-map "M-n" #'jinx-next)
  (keymap-set emacs-anywhere-mode-map "M-p" #'jinx-previous))

;; Auto-customisations
(setq-default custom-file (locate-user-emacs-file ".custom.el"))
(when (file-exists-p custom-file)
  (load custom-file 'noerror 'nomessage))

;; kill confirmation
(setopt kill-whole-line t
        confirm-kill-processes nil
        ns-confirm-quit nil
        use-dialog-box nil)

;; mitigate very long line performance issue
(global-so-long-mode)

(setopt initial-major-mode 'text-mode)

;; Mispressing C-z invokes `suspend-frame' (disable).
(global-unset-key (kbd "C-z"))

(setq frame-title-format
      '((:eval (if (buffer-file-name)
                   (my/shorten-path-for-title (abbreviate-file-name (buffer-file-name)))))
        (:eval (if (not (buffer-file-name)) (buffer-name)))))

(pixel-scroll-precision-mode t)

;; enable right click menu use M-` for tmm-menubar
(context-menu-mode)

(global-prettify-symbols-mode)

(delete-selection-mode t)

(setq-default fill-column 80)

(setopt require-final-newline t)

(add-hook 'focus-out-hook (lambda () (save-some-buffers "!")))
(setopt native-comp-async-report-warnings-errors 'silent)

(setopt vc-handled-backends '(Git))

(setopt fast-but-imprecise-scrolling t)

(setopt idle-update-delay 1.0)

(electric-pair-mode -1)

(recentf-mode t)

(setopt history-length 25)

(setopt global-auto-revert-non-file-buffers t)
(global-auto-revert-mode t)

(setq ring-bell-function 'ignore)

(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)
(setopt bidi-inhibit-bpa t)

(setopt redisplay-skip-fontification-on-input t)

(setopt read-process-output-max (* 4 1024 1024))

(setq-default cursor-in-non-selected-windows nil)
(setopt highlight-nonselected-windows nil)

(setopt save-interprogram-paste-before-kill t)

(setopt kill-do-not-save-duplicates t)

(require 'cl-lib)

(savehist-mode t)
(dolist (var '(search-ring regexp-search-ring kill-ring))
  (add-to-list 'savehist-additional-variables var))

(defun backbone/savehist-strip-kill-ring-text-properties ()
  "Remove text properties from kill-ring entries before saving history."
  (setq kill-ring
        (mapcar #'substring-no-properties
                (cl-remove-if-not #'stringp kill-ring))))

(add-hook 'savehist-save-hook #'backbone/savehist-strip-kill-ring-text-properties)

(save-place-mode t)

(add-hook 'after-save-hook #'executable-make-buffer-file-executable-if-script-p)

(setq reb-re-syntax 'string)

(setopt ffap-machine-p-known 'reject)

(setopt window-combination-resize t)

(winner-mode 1)

(defun backbone/toggle-delete-other-windows ()
  "Delete other windows, or undo the last such change."
  (interactive)
  (if (and winner-mode
           (equal (selected-window) (next-window)))
      (winner-undo)
    (delete-other-windows)))

(keymap-global-set "C-x 1" #'backbone/toggle-delete-other-windows)

(setopt set-mark-command-repeat-pop t)

(defun backbone/recenter-after-save-place ()
  "Recenter the window after `save-place' restores point."
  (when buffer-file-name
    (ignore-errors (recenter))))

(advice-add 'save-place-find-file-hook :after #'backbone/recenter-after-save-place)

(setopt help-window-select t)

(autoload 'zap-up-to-char "misc"
  "Kill up to, but not including ARGth occurrence of CHAR." t)

(require 'uniquify)
(setq uniquify-buffer-name-style 'forward)

(global-set-key (kbd "M-/") 'hippie-expand)
(global-set-key (kbd "C-x C-b") 'ibuffer)
(global-set-key (kbd "M-z") 'zap-up-to-char)

(global-set-key (kbd "C-s") 'isearch-forward-regexp)
(global-set-key (kbd "C-r") 'isearch-backward-regexp)
(global-set-key (kbd "C-M-s") 'isearch-forward)
(global-set-key (kbd "C-M-r") 'isearch-backward)

(setq apropos-do-all t
      mouse-yank-at-point t
      backup-by-copying t
      frame-inhibit-implied-resize t
      read-file-name-completion-ignore-case t
      read-buffer-completion-ignore-case t
      completion-ignore-case t
      ediff-window-setup-function 'ediff-setup-windows-plain)

(unless backup-directory-alist
  (setq backup-directory-alist `(("." . ,(concat emacs-backbone-user-directory
                                                 "/backups")))))

(package! persistent-scratch)
(config-unit! persistent-scratch
  :requires persistent-scratch
  :config
  (persistent-scratch-setup-default))

(package! immortal-scratch :repo "jpkotta/immortal-scratch" :branch "master")
(config-unit! immortal-scratch
  :requires immortal-scratch
  :config
  (immortal-scratch-mode 1))

(package! popper :repo "karthink/popper" :branch "master")

(defvar my/popper-side-threshold 160
  "Minimum frame width in columns before F9 popups use a side window.")

(defun my/frame-prefers-side-popups-p (&optional frame)
  "Return non-nil when FRAME is wide enough and landscape-oriented."
  (let ((frame (or frame (selected-frame))))
    (and (>= (frame-width frame) my/popper-side-threshold)
         (> (frame-pixel-width frame)
            (frame-pixel-height frame)))))

(defun my/popper-display-popup (buffer &optional alist)
  "Display popper BUFFER on the right for wide frames, bottom otherwise."
  (let ((window
         (if (my/frame-prefers-side-popups-p)
             (display-buffer-in-side-window
              buffer
              (append alist
                      '((side . right)
                        (slot . 0)
                        (window-width . 0.33))))
           (popper-display-popup-at-bottom buffer alist))))
    (select-window window)))

(config-unit! popper
  :requires popper
  :config
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "Output\\*$"
          "\\*Async Shell Command\\*"
          "\\*scratch\\*"
          help-mode
          compilation-mode))
  (setopt popper-display-function #'my/popper-display-popup)
  (keymap-global-set "<f9>" #'popper-toggle)
  (keymap-global-set "M-<f9>" #'popper-cycle)
  (keymap-global-set "C-<f9>" #'popper-toggle-type)
  (popper-mode +1)
  (popper-echo-mode +1))

(defun er-keyboard-quit ()
  "Smarter version of the built-in `keyboard-quit'.

The generic `keyboard-quit' does not do the expected thing when
the minibuffer is open.  Whereas we want it to close the
minibuffer, even without explicitly focusing it."
  (interactive)
  (if (active-minibuffer-window)
      (if (minibufferp)
          (minibuffer-keyboard-quit)
        (abort-recursive-edit))
    (keyboard-quit)))

(global-set-key [remap keyboard-quit] #'er-keyboard-quit)

;; Disable tabs globally
(setq-default indent-tabs-mode nil)

;; Set the default tab width (number of spaces per tab)
(setq-default tab-width 4) ;; Adjust 4 to your preferred number of spaces

(setq-default whitespace-style '(face empty tabs newline trailing tab-mark))

;; Don't enable whitespace for.
(setq-default whitespace-global-modes
              '(not
                shell-mode
                help-mode
                magit-mode
                magit-diff-mode
                ibuffer-mode
                dired-mode
                occur-mode))

(global-whitespace-mode t)

(package! helpful)
(config-unit! essentials
  :config
  (global-set-key (kbd "C-h f") #'helpful-callable)
  (global-set-key (kbd "C-h v") #'helpful-variable)
  (global-set-key (kbd "C-h k") #'helpful-key)
  (global-set-key (kbd "C-h x") #'helpful-command)
  ;; Lookup the current symbol at point
  (global-set-key (kbd "C-c C-d") #'helpful-at-point)
  (defvar-keymap emacs-hypervisor-reload-prefix-map
    :doc "Hypervisor reload utilities"
    "e" #'emacs-hypervisor-tangle-config
    "r" #'emacs-hypervisor-reload-config)
  (keymap-set help-map "r" emacs-hypervisor-reload-prefix-map)
  (when (fboundp 'which-key-add-keymap-based-replacements)
    (which-key-add-keymap-based-replacements
      help-map
      "r"
      `("Hypervisor" . ,emacs-hypervisor-reload-prefix-map))))

(package! restart-emacs)

(config-unit! restart-emacs-util
  :requires (restart-emacs transient)
  :config

  (defun backbone/restart-and-restore (&optional debug &rest _ignored)
    "Restart Emacs (and the daemon, if active).
If DEBUG (the prefix arg) is given, start the new instance with the --debug switch."
    (interactive "P")
    (save-some-buffers nil t)
    (cl-letf (((symbol-function 'save-buffers-kill-emacs)
               (lambda (&rest args)
                 (apply #'kill-emacs args))))
      (let ((confirm-kill-emacs nil))
        (restart-emacs (if debug '("--debug-init") nil))))))

(defun backbone/restart-and-restore-suffix (&optional debug &rest _ignored)
  "Restart Emacs from the quit transient."
  (interactive "P")
  (backbone/restart-and-restore debug))

(package! beacon :repo "Malabarba/beacon" :branch "master")
(package! rainbow-mode)
(package! rainbow-delimiters)

(config-unit! global-enabled-modes
  :requires (rainbow-mode rainbow-delimiters)
  :config

  (add-hook 'prog-mode-hook (lambda () (rainbow-mode t)))

  (add-hook 'prog-mode-hook #'rainbow-delimiters-mode)

  (repeat-mode t)

  (beacon-mode t))

(package! perfect-margin)

(config-unit! perfect-margin
  :requires perfect-margin
  :config
  (setopt perfect-margin-enable-debug-log nil)
  (setopt perfect-margin-only-set-left-margin t)
  (setopt perfect-margin-visible-width 175)

  ;; Center completion minibuffer
  (add-to-list 'perfect-margin-force-regexps "*Minibuf")
  (add-to-list 'perfect-margin-force-regexps "*which-key")
  ;; Ignore buffers
  (add-to-list 'perfect-margin-ignore-modes 'help-mode)
  (add-to-list 'perfect-margin-ignore-modes 'magit-mode)
  (add-to-list 'perfect-margin-ignore-modes 'agent-shell-mode)
  (add-to-list 'perfect-margin-ignore-modes 'markdown-mode)
  (add-to-list 'perfect-margin-ignore-modes 'gfm-mode)

  (perfect-margin-mode t))

(package! pcre2el)
(package! visual-regexp-steroids :deps pcre2el)
(package! transient :repo "magit/transient" :branch "main")

(config-unit! visual-regexp-steroids
  :requires (pcre2el visual-regexp-steroids)
  :config (setopt vr/engine 'pcre2el))

(package! ws-butler)

(config-unit! ws-butler
  :requires ws-butler
  :config
  (add-hook 'prog-mode-hook #'ws-butler-mode)
  ;; don't delete whitespace of currently editting line
  (setopt ws-butler-keep-whitespace-before-point t))

(package! magit :deps transient)
(package! magit-pre-commit)

(config-unit! magit
  :requires magit
  :executable git
  :config
  (keymap-set magit-mode-map "C-c C-o" #'backbone/magit-open-repo)
  (keymap-set magit-mode-map "C-c C-m" #'backbone/magit-claude-commit)

  ;; Use Magit's full-column layout so status gets the frame and revision/diff
  ;; buffers open beside it instead of always dropping to the bottom.
  (setopt magit-display-buffer-function 'magit-display-buffer-fullcolumn-most-v1)

  ;; Don't immediately force the process buffer open for short-lived commands.
  (setopt magit-process-popup-time 1)

  ;; Use pipes instead of PTYs to prevent terminal control sequences (ESC[2K)
  (setopt magit-process-connection-type nil)

  ;; Apply ANSI colors continuously in process buffer
  (setopt magit-process-apply-ansi-colors 'filter)

  ;; --- Performance ---

  ;; Disable Emacs' built-in VC for Git repos. VC runs redundant git queries
  ;; on every file visit; magit replaces it entirely so VC is dead weight.
  ;; Keep `project.el` working by providing a lightweight Git project finder
  ;; that does not depend on VC Git being enabled.
  (defun backbone/project-try-git (dir)
    "Detect Git projects for `project.el' without full VC Git integration."
    (when-let ((root (locate-dominating-file dir ".git")))
      (list 'vc 'Git (expand-file-name root))))

  (add-hook 'project-find-functions #'backbone/project-try-git)
  (setq vc-handled-backends (delq 'Git vc-handled-backends))

  ;; When viewing a commit, magit normally queries which branches/tags contain
  ;; it — expensive on repos with many refs. Disable for faster commit views.
  (setopt magit-revision-insert-related-refs nil)

  ;; The tags header scans all refs to find the nearest tag on every status
  ;; refresh. Remove it to speed up opening the status buffer.
  (remove-hook 'magit-status-sections-hook 'magit-insert-tags-header)

  ;; --- Diff quality ---

  ;; Show word-level highlighting on ALL hunks, not just the one under point.
  ;; Makes the entire diff scannable at a glance.
  (setopt magit-diff-refine-hunk 'all)

  ;; Only highlight trailing whitespace errors in uncommitted changes, not in
  ;; historical diffs. Catches real mistakes without noise when browsing history.
  (setopt magit-diff-paint-whitespace 'uncommitted)

  ;; --- Workflow ---

  ;; Auto-save all modified repo buffers before magit commands, without
  ;; prompting. Ensures git always sees the current state of files.
  (setopt magit-save-repository-buffers 'dontask)

  ;; Collapse the stashes section by default. Keeps the status buffer tidy
  ;; when stashes accumulate over time.
  (setopt magit-section-initial-visibility-alist '((stashes . hide)))

  ;; Refresh the status buffer automatically whenever a file is saved.
  ;; No more pressing g manually after every edit.
  (add-hook 'after-save-hook #'magit-after-save-refresh-status)

  ;; --- Commit message hygiene ---

  ;; Color the summary line red when it exceeds 50 chars (the conventional
  ;; limit), and auto-fill the body at 72 columns.
  (setopt git-commit-summary-max-length 50)
  (setopt git-commit-fill-column 72))

(defun backbone/magit-claude-commit ()
  "Commit staged changes using Claude to generate the message."
  (interactive)
  (let ((default-directory (magit-toplevel)))
    (unless default-directory
      (user-error "Not inside a Git repository"))
    (unless (magit-anything-staged-p)
      (user-error "Nothing staged to commit"))
    (compile "claude --model sonnet -p '/git-commit'")))

(defun backbone/magit-remote-url-to-https (url)
  "Convert git remote URL to a browsable HTTPS URL."
  (cond
   ((string-match-p "\\`https?://" url)
    (replace-regexp-in-string "\\.git\\'" "" url))
   ((string-match "\\`git@\\([^:]+\\):\\(.+?\\)\\(?:\\.git\\)?\\'" url)
    (format "https://%s/%s" (match-string 1 url) (match-string 2 url)))
   ((string-match "\\`ssh://git@\\([^/]+\\)/\\(.+?\\)\\(?:\\.git\\)?\\'" url)
    (format "https://%s/%s" (match-string 1 url) (match-string 2 url)))
   (t url)))

(defun backbone/magit-open-repo ()
  "Open the current repository's `origin' remote in a browser."
  (interactive)
  (if-let ((url (magit-get "remote" "origin" "url")))
      (browse-url (backbone/magit-remote-url-to-https url))
    (user-error "No origin remote configured for this repository")))

;; Theme is loaded in Built-In Settings -> Theme section

(package! mood-line)

(config-unit! mood-line
  :requires mood-line
  :config
  (mood-line-mode 1))

(package! ace-window)

(config-unit! window-settings
  :config
  (keymap-set global-map "M-o" #'ace-window)
  (keymap-set global-map "M-O" #'ace-swap-window)
  (setopt aw-ignore-on t)
  (setopt aw-scope 'frame))

(package! popwin)
(config-unit! popwin
  :requires popwin
  :config
  (push 'helpful-mode               popwin:special-display-config)
  (push emacs-backbone-buffer-name popwin:special-display-config)
  (push "*Shell Command Output*"    popwin:special-display-config)
  (push '("*compilation*" :position right :width 80 :stick t) popwin:special-display-config)

  (popwin-mode t))

(package! vertico)
(package! orderless)
(package! hotfuzz)
(package! hotfuzz-with-orderless :repo "lewang/hotfuzz-with-orderless" :branch "main" :deps (hotfuzz orderless))
(package! consult)
(package! marginalia)
(package! embark)
(package! embark-consult :deps (embark consult))

(config-unit! minibuffer-settings
  :requires (vertico orderless hotfuzz hotfuzz-with-orderless consult marginalia)
  :config
  (setopt vertico-cycle t)
  (setopt vertico-resize nil)
  (vertico-mode 1)

  ;; Completion: hotfuzz-with-orderless combines fuzzy + multi-token
  ;; Type "cfgnx" → fuzzy match "config.nix"
  ;; Type "cfg nix" → "cfg" fuzzy, "nix" orderless token
  (setopt completion-styles '(hotfuzz-with-orderless basic))

  ;; Enable rich annotations in the minibuffer
  (marginalia-mode 1)

  ;; Live visual feedback when composing regexps in the minibuffer (Emacs 30+)
  (minibuffer-regexp-mode 1)

  (keymap-set global-map "C-c SPC" #'consult-project-buffer)
  (keymap-set global-map "C-c C-SPC" #'consult-buffer))

(config-unit! embark
  :requires embark
  :config
  (defun backbone/parse-file-reference (string)
    "Parse STRING as `file[:line[:column]]' and return a plist."
    (when (and string
               (string-match
                "\\`\\(.+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\'"
                string))
      (when-let ((path (match-string 1 string))
                 (expanded-path (expand-file-name path)))
        (when (file-exists-p expanded-path)
          (list :string string
                :path expanded-path
                :line (string-to-number (match-string 2 string))
                :column (when-let ((column (match-string 3 string)))
                          (string-to-number column)))))))

  (defun backbone/file-reference-at-point ()
    "Return the `file[:line[:column]]' reference at point as a plist."
    (when-let* ((raw-token
                 (save-excursion
                   (skip-chars-backward "^ \t\n\"'`<>()[]{}")
                   (let ((start (point)))
                     (skip-chars-forward "^ \t\n\"'`<>()[]{}")
                     (buffer-substring-no-properties start (point)))))
                (token (string-trim raw-token "[\"'`([{<]+" "[\"'`.,;!?)}\]>]+")))
      (backbone/parse-file-reference token)))

  (defun backbone/embark-target-file-reference-at-point ()
    "Return an Embark target for `file[:line[:column]]' at point."
    (when-let ((reference (backbone/file-reference-at-point)))
      (list 'file-reference (plist-get reference :string))))

  (defun backbone/embark-open-file-reference (reference)
    "Open REFERENCE, a string in `file[:line[:column]]' format."
    (interactive "sFile reference: ")
    (if-let* ((parsed-reference (backbone/parse-file-reference reference))
              (path (plist-get parsed-reference :path)))
        (progn
          (find-file path)
          (goto-char (point-min))
          (forward-line (1- (max (plist-get parsed-reference :line) 1)))
          (when-let ((column (plist-get parsed-reference :column)))
            (move-to-column (max (1- column) 0))))
      (user-error "Invalid file reference: %s" reference)))

  (defvar-keymap backbone/embark-file-reference-map
    :doc "Embark actions for file references."
    "RET" #'backbone/embark-open-file-reference
    "o" #'backbone/embark-open-file-reference)

  (add-to-list 'embark-target-finders #'backbone/embark-target-file-reference-at-point)
  (add-to-list 'embark-keymap-alist '(file-reference . backbone/embark-file-reference-map))
  (add-to-list 'embark-default-action-overrides '(file-reference . backbone/embark-open-file-reference))

  ;; C-h after any prefix opens a completing-read of the prefix's bindings.
  (setopt prefix-help-command #'embark-prefix-help-command)
  (keymap-set global-map "C-."   #'embark-act)
  (keymap-set global-map "C-;"   #'embark-dwim)
  (keymap-set global-map "C-h B" #'embark-bindings))

(package! websocket)
;; Use the local checkout while iterating on consult-snapfile itself.
(package! consult-snapfile
  :local "~/projects/consult-snapfile/emacs"
  :deps (consult websocket))

(config-unit! consult-snapfile
  :requires consult-snapfile
  :config
  ;; Max results returned from server (default: 100)
  (setopt consult-snapfile-max-results 100))

(package! appine :repo "chaoswork/appine" :branch "master")

(defun backbone/appine-supported-p ()
  "Return non-nil when the current Emacs can run Appine."
  (and (eq system-type 'darwin)
       (fboundp 'module-load)))

(defun backbone/appine-ensure-loaded ()
  "Load Appine on demand and enable Org link integration."
  (unless (backbone/appine-supported-p)
    (user-error "Appine requires macOS Emacs with dynamic module support"))
  (unless (featurep 'appine)
    (require 'appine))
  (setopt appine-use-for-org-links t))

(defun backbone/appine ()
  "Open the Appine window."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine))

(defun backbone/appine-open-url (url)
  "Open URL in Appine."
  (interactive "sURL: ")
  (backbone/appine-ensure-loaded)
  (appine-open-url url))

(defun backbone/appine-open-file (path)
  "Open PATH in Appine."
  (interactive "fFile: ")
  (backbone/appine-ensure-loaded)
  (appine-open-file path))

(defun backbone/appine-new-tab ()
  "Create a new Appine tab."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-new-tab))

(defun backbone/appine-prev-tab ()
  "Select the previous Appine tab."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-prev-tab))

(defun backbone/appine-next-tab ()
  "Select the next Appine tab."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-next-tab))

(defun backbone/appine-close-tab ()
  "Close the current Appine tab."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-close-tab))

(defun backbone/appine-web-go-back ()
  "Go back in the current Appine web view."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-web-go-back))

(defun backbone/appine-web-go-forward ()
  "Go forward in the current Appine web view."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-web-go-forward))

(defun backbone/appine-web-reload ()
  "Reload the current Appine web view."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-web-reload))

(defun backbone/appine-close ()
  "Close the current Appine window."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-close))

(defun backbone/appine-kill ()
  "Kill the Appine window and native view."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-kill))

(defun backbone/appine-toggle-use-for-org-links ()
  "Toggle Appine handling for Org URLs and non-Org files."
  (interactive)
  (backbone/appine-ensure-loaded)
  (call-interactively #'appine-toggle-use-for-org-links))

(defun backbone/org-open-at-point-with-appine ()
  "Open supported Org links in Appine, loading it on demand."
  (when (backbone/appine-supported-p)
    (when-let* ((context (ignore-errors (org-element-context)))
                ((eq (org-element-type context) 'link))
                (link-type (org-element-property :type context))
                (path (org-element-property :path context)))
      (cond
       ((member link-type '("http" "https"))
        (backbone/appine-open-url (concat link-type ":" path))
        t)
       ((and (equal link-type "file")
             (not (string-suffix-p ".org" path t)))
        (backbone/appine-open-file path)
        t)))))

(with-eval-after-load 'org
  (add-hook 'org-open-at-point-functions #'backbone/org-open-at-point-with-appine))

(config-unit! appine-menu
  :requires transient
  :config
  (transient-define-prefix my/appine-menu ()
    "Appine commands."
    [["Open"
      ("a" "window" backbone/appine)
      ("u" "URL" backbone/appine-open-url)
      ("f" "file" backbone/appine-open-file)]
     ["Tabs"
      ("t" "new tab" backbone/appine-new-tab)
      ("[" "prev tab" backbone/appine-prev-tab)
      ("]" "next tab" backbone/appine-next-tab)
      ("w" "close tab" backbone/appine-close-tab)]
     ["Browse"
      ("b" "back" backbone/appine-web-go-back)
      ("g" "forward" backbone/appine-web-go-forward)
      ("r" "reload" backbone/appine-web-reload)]
     ["Mode"
      ("o" "toggle Org links" backbone/appine-toggle-use-for-org-links)
      ("0" "close window" backbone/appine-close)
      ("k" "kill Appine" backbone/appine-kill)]]))

(package! dired-single :repo "emacsattic/dired-single" :branch "master")
(package! dired+ :repo "emacsmirror/dired-plus" :branch "master")
(package! dired-subtree)

(config-unit! dired
  :requires (dired-single dired+ dired-subtree)
  :config
  (setopt delete-by-moving-to-trash t
          dired-listing-switches "-agho --group-directories-first"
          dired-subtree-use-backgrounds nil)

  (define-key dired-mode-map [remap dired-find-file] #'dired-single-buffer)
  (define-key dired-mode-map [remap dired-mouse-find-file-other-window] #'dired-single-buffer-mouse)
  (define-key dired-mode-map [remap dired-up-directory] #'dired-single-up-directory)
  (keymap-set dired-mode-map "i" #'dired-subtree-insert)
  (keymap-set dired-mode-map ";" #'dired-subtree-remove)

  (global-set-key [(f6)] #'dired-single-magic-buffer)
  (global-set-key [(shift f6)]
                  (lambda ()
                    (interactive)
                    (dired-single-magic-buffer default-directory))))

;; (setq display-line-numbers-type nil)
(defvar backbone/line-number-exempt-modes
  '(agent-shell-mode
    ghostel-mode)
  "Major modes where line numbers should stay disabled.")

(defun backbone/disable-line-numbers ()
  "Disable line numbers in the current buffer."
  (display-line-numbers-mode -1))

(defun backbone/apply-line-number-exemptions ()
  "Disable line numbers in buffers listed in `backbone/line-number-exempt-modes'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (apply #'derived-mode-p backbone/line-number-exempt-modes)
        (backbone/disable-line-numbers)))))

(unless global-display-line-numbers-mode
  (global-display-line-numbers-mode 1))
(backbone/apply-line-number-exemptions)

;; Ensures that scrolling commands keep the cursor at its current screen position.
(setq scroll-preserve-screen-position t)
;; Prevents aggressive recentering of the cursor during scrolling
(setq scroll-conservatively 101)

(define-key global-map [remap exchange-point-and-mark] #'my/exchange-point-and-mark-no-activate)

;; Insert line below without splitting current line
;; Default C-o splits at cursor; this always adds blank line below
(defun my/insert-line-below ()
  "Insert an empty line below the current line."
  (interactive)
  (save-excursion
    (end-of-line)
    (open-line 1)))

(define-key global-map [remap open-line] #'my/insert-line-below)

(show-paren-mode t)

(package! expreg)

(config-unit! expreg
  :requires expreg
  :config
  (keymap-set global-map "C-M-o" #'expreg-expand))

(package! crux)
(package! unfill)
(package! shrink-whitespace)
(package! surround :repo "mkleehammer/surround" :branch "main")
(package! move-text)

(config-unit! editting-settings
  :requires (unfill shrink-whitespace surround move-text)
  :config
  (keymap-set global-map "C-a" #'crux-move-beginning-of-line)
  (keymap-set global-map "M-C" #'whitespace-cleanup)
  (keymap-set global-map "M-N" #'move-text-down)
  (keymap-set global-map "M-P" #'move-text-up)
  (keymap-set global-map "M-n" #'flymake-goto-next-error)
  (keymap-set global-map "M-p" #'flymake-goto-prev-error)
  (keymap-set global-map "M-q" #'unfill-toggle)
  (keymap-set global-map "M-u" #'my/xah-toggle-letter-case)
  (keymap-set global-map "C-M-SPC" #'shrink-whitespace)

  ;; Surround keybinding
  (keymap-set global-map "M-'" surround-keymap)

  (setopt duplicate-line-final-position 1)
  (keymap-set global-map "M-l" #'duplicate-dwim)
  )

(package! avy)

(config-unit! avy-config
  :requires avy
  :config
  (setopt avy-style 'de-bruijn)

  (set-face-attribute 'avy-lead-face nil :foreground "orange")
  (setopt avy-background nil)

  (let ((avy-support-file
         (expand-file-name "config/avy-can-do-anything.el" emacs-backbone-user-directory)))
    (when (file-exists-p avy-support-file)
      (load-file avy-support-file))))

(package! vundo)

(config-unit! vundo
  :requires vundo
  :config
  ;; Bind vundo to C-x u (overrides default undo)
  (keymap-set global-map "C-x u" #'vundo)
  ;; Visual settings for better readability
  (setopt vundo-glyph-alist vundo-unicode-symbols))

(config-unit! enhanced-view-mode
  :config
  ;; Define the face for the header-line banner
  (defface my/view-mode-header-face
    '((t :background "#98971a"
         :foreground "#282828"
         :weight bold
         :height 0.9))
    "Face for enhanced view mode header line."
    :group 'my/view-mode)

  ;; Store original header-line-format per buffer
  (defvar-local my/view-mode--original-header-line nil
    "Stores the original header-line-format before enabling view mode.")

  (defvar-local my/view-mode--header-line-remap-cookie nil
    "Cookie for face-remapping of header-line face.")

  (defvar-local my/view-mode--enhanced-active nil
    "Non-nil when enhanced view mode bindings are active.")

  ;; Tree-sitter aware navigation functions
  (defun my/view-mode-next-defun ()
    "Move to the next defun, tree-sitter aware."
    (interactive)
    (if (and (fboundp 'treesit-parser-list)
             (treesit-parser-list))
        ;; Use tree-sitter navigation
        (end-of-defun)
      ;; Fallback to standard defun navigation
      (end-of-defun))
    ;; Move to beginning of the defun we just passed
    (beginning-of-defun)
    (when (= (point) (point-min))
      (end-of-defun)
      (beginning-of-defun)))

  (defun my/view-mode-prev-defun ()
    "Move to the previous defun, tree-sitter aware."
    (interactive)
    (beginning-of-defun))

  ;; Header line format for view mode
  (defun my/view-mode-header-line ()
    "Generate the header line for enhanced view mode."
    (let ((keys-help "n:next  p:prev  SPC:scroll-up ⇧ SPC:scroll-down q:quit"))
      (concat
       (propertize " 📖 VIEW " 'face '(:inherit my/view-mode-header-face :weight bold))
       (propertize (concat " " keys-help)
                   'face '(:inherit my/view-mode-header-face :weight normal)))))

  ;; Define the keymap for enhanced view mode
  (defvar my/view-mode-map
    (let ((map (make-sparse-keymap)))
      (define-key map "n" #'my/view-mode-next-defun)
      (define-key map "p" #'my/view-mode-prev-defun)
      (define-key map " " #'scroll-up-command)
      (define-key map (kbd "S-SPC") #'scroll-down-command)
      (define-key map (kbd "DEL") #'scroll-down-command)
      (define-key map "q" #'my/enhanced-view-mode-off)
      (define-key map "v" #'my/enhanced-view-mode-off) ; v again to exit
      map)
    "Keymap for enhanced view mode.")

  ;; Repeat map for fluid n/p navigation
  (defvar my/view-mode-repeat-map
    (let ((map (make-sparse-keymap)))
      (define-key map "n" #'my/view-mode-next-defun)
      (define-key map "p" #'my/view-mode-prev-defun)
      map)
    "Repeat map for view mode navigation.")

  (put 'my/view-mode-next-defun 'repeat-map 'my/view-mode-repeat-map)
  (put 'my/view-mode-prev-defun 'repeat-map 'my/view-mode-repeat-map)

  (defun my/enhanced-view-mode-on ()
    "Enable enhanced view mode with header line and custom bindings."
    (interactive)
    (unless my/view-mode--enhanced-active
      ;; Save original header-line
      (setq my/view-mode--original-header-line header-line-format)
      ;; Remap header-line face to use our colors for the entire line
      (setq my/view-mode--header-line-remap-cookie
            (face-remap-add-relative 'header-line 'my/view-mode-header-face))
      ;; Set the view mode header line
      (setq header-line-format '(:eval (my/view-mode-header-line)))
      ;; Make buffer read-only
      (read-only-mode 1)
      ;; Activate our keymap as a minor-mode-like overlay
      (setq my/view-mode--enhanced-active t)
      ;; Push our keymap to the front
      (push (cons 'my/view-mode--enhanced-active my/view-mode-map)
            minor-mode-overriding-map-alist)
      (message "Enhanced View Mode enabled")))

  (defun my/enhanced-view-mode-off ()
    "Disable enhanced view mode."
    (interactive)
    (when my/view-mode--enhanced-active
      ;; Restore original header-line
      (setq header-line-format my/view-mode--original-header-line)
      ;; Remove face remapping
      (when my/view-mode--header-line-remap-cookie
        (face-remap-remove-relative my/view-mode--header-line-remap-cookie)
        (setq my/view-mode--header-line-remap-cookie nil))
      ;; Disable read-only mode
      (read-only-mode -1)
      ;; Remove our keymap
      (setq minor-mode-overriding-map-alist
            (assq-delete-all 'my/view-mode--enhanced-active
                             minor-mode-overriding-map-alist))
      (setq my/view-mode--enhanced-active nil)
      (message "Enhanced View Mode disabled")))

  (defun my/enhanced-view-mode-toggle ()
    "Toggle enhanced view mode."
    (interactive)
    (if my/view-mode--enhanced-active
        (my/enhanced-view-mode-off)
      (my/enhanced-view-mode-on)))

  ;; Global keybinding
  (keymap-set global-map "C-c v v" #'my/enhanced-view-mode-toggle)

  ;; Add to which-key
  (which-key-add-keymap-based-replacements global-map
    "C-c v" "view"))

(package! multiple-cursors)
(config-unit! multiple-cursors
  :requires multiple-cursors
  :config
  (defvar-keymap my/multiple-cursors-keymap
    "l"         #'mc/edit-lines
    "n"         #'mc/mark-next-like-this
    "N"         #'mc/unmark-next-like-this
    "p"         #'mc/mark-previous-like-this
    "P"         #'mc/unmark-previous-like-this
    "t"         #'mc/mark-all-like-this
    "m"         #'mc/mark-all-like-this-dwim
    "e"         #'mc/edit-ends-of-lines
    "a"         #'mc/edit-beginnings-of-lines
    "s"         #'mc/mark-sgml-tag-pair
    "d"         #'mc/mark-all-like-this-in-defun
    "<mouse-1>" #'mc/add-cursor-on-click)

  (keymap-set global-map "C-c m" my/multiple-cursors-keymap)

  (which-key-add-keymap-based-replacements global-map
    "C-c m" `("multiple-cursor" . ,my/multiple-cursors-keymap))

  (defvar my/mc-repeat-map
    (let ((map (make-sparse-keymap)))
      (define-key map "n" #'mc/mark-next-like-this)
      (define-key map "p" #'mc/mark-previous-like-this)
      map)
    "Repeating map for multiple cursors")

  (put 'mc/mark-next-like-this     'repeat-map 'my/mc-repeat-map)
  (put 'mc/mark-previous-like-this 'repeat-map 'my/mc-repeat-map))

(package! wgrep)
(package! rg :deps wgrep)

(setopt compilation-scroll-output 'first-error)

(package! yasnippet)
(package! lsp-bridge
  :repo "manateelazycat/lsp-bridge"
  :branch "master"
  :files ("*.el" "*.py" "acm" "core" "langserver" "multiserver" "resources")
  :no-compilation t
  :deps (markdown-mode yasnippet))

(package! flymake-bridge :repo "liuyinz/flymake-bridge" :branch "master" :deps lsp-bridge)

(config-unit! lsp-bridge
  :requires lsp-bridge
  :config
  ;; Mark lsp-bridge-python-command as safe for .dir-locals.el
  (put 'lsp-bridge-python-command 'safe-local-variable #'stringp)

  (add-hook 'prog-mode-hook #'lsp-bridge-mode)
  (add-hook 'org-mode-hook #'lsp-bridge-mode)
  ;; English dictionary completion only in text buffers, not code
  (add-hook 'text-mode-hook (lambda () (setq-local acm-enable-english-helper t)))

  (keymap-set global-map "M-."   #'lsp-bridge-find-def)
  (keymap-set global-map "M-,"   #'lsp-bridge-find-def-return)
  (keymap-set global-map "C-M-." #'lsp-bridge-code-action)

  ;; global settings
  (setopt acm-enable-yas nil)
  (setopt acm-enable-word t)
  (setopt lsp-bridge-enable-auto-format-code nil)
  (setopt lsp-bridge-enable-log nil)
  (setopt lsp-bridge-find-def-select-in-open-windows t)
  (setopt lsp-bridge-enable-inlay-hint nil
          lsp-bridge-enable-hover-diagnostic t)

  ;; Let lsp-bridge manage its Python deps via PEP 723 metadata and `uv run`.
  (setopt lsp-bridge-python-command "uv")

  ;; work with org source code block
  (setopt lsp-bridge-enable-org-babel t))

(config-unit! lsp-bridge-language-server :after lsp-bridge
  :config
  (setq lsp-bridge-python-multi-lsp-server "basedpyright_ruff"))

(config-unit! lsp-bridge-flymake-bridge :after lsp-bridge
  :requires flymake-bridge
  :config
  (add-hook 'lsp-bridge-mode-hook #'flymake-bridge-setup))

(config-unit! lsp-bridge-orderless :after lsp-bridge
  :requires orderless
  :config
  (setopt acm-candidate-match-function 'orderless-regexp))

(package! fish-mode)
(config-unit! fish-mode
  :requires fish-mode
  :config
  (add-to-list 'auto-mode-alist '("\\.fish\\'" . fish-mode)))

(package! gleam-ts-mode :repo "gleam-lang/gleam-mode" :branch "main" :files ("gleam-ts-*.el"))
(config-unit! gleam-ts-mode
  :requires gleam-ts-mode
  :config
  (add-to-list 'auto-mode-alist '("\\.gleam\\'" . gleam-ts-mode))

  (setopt treesit-extra-load-path (list (expand-file-name "~/.local/tree-sitter/")))
  (unless (treesit-language-available-p 'gleam)
    ;; hack: change `out-dir' when install language-grammar'
    (let ((orig-treesit--install-language-grammar-1 (symbol-function 'treesit--install-language-grammar-1)))
      (cl-letf (((symbol-function 'treesit--install-language-grammar-1)
                 (lambda (out-dir lang url)
                   (funcall orig-treesit--install-language-grammar-1
                            "~/.local/tree-sitter/" lang url))))
        (gleam-ts-install-grammar)))))

(package! just-mode)

(package! lua-mode)
(config-unit! lua-mode
  :requires lua-mode
  :config
  (add-to-list 'auto-mode-alist '("\\.lua\\'" . lua-mode))

  (autoload 'lua-mode "lua-mode" "Lua editing mode." t)
  (setopt lua-indent-level 2)

  ;; hack from https://stackoverflow.com/a/67176958/22903883
  (setopt lua-indent-nested-block-content-align nil)
  (setopt lua-indent-close-paren-align nil)

  (defun lua-at-most-one-indent (old-function &rest arguments)
    (let ((old-res (apply old-function arguments)))
      (if (> old-res lua-indent-level) lua-indent-level old-res)))

  (advice-add #'lua-calculate-indentation-block-modifier
              :around #'lua-at-most-one-indent))

(package! nix-mode)
(add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode))

(package! highlight-defined)

(config-unit! highlight-defined
  :requires highlight-defined
  :config
  (add-hook 'emacs-lisp-mode-hook #'highlight-defined-mode))

(package! edit-indirect)
(package! markdown-mode :deps edit-indirect)

(config-unit! markdown
  :requires markdown-mode
  :config

  (autoload 'markdown-mode "markdown-mode"
    "Major mode for editing Markdown files" t)
  (autoload 'gfm-mode "markdown-mode"
    "Major mode for editing GitHub Flavored Markdown files" t)

  ;; Add general .md support
  (add-to-list 'auto-mode-alist '("\\.md\\'" . markdown-mode))
  (add-to-list 'auto-mode-alist '("\\.markdown\\'" . markdown-mode))
  (add-to-list 'auto-mode-alist '("README\\.md\\'" . gfm-mode)))

(package! grip-mode)

(config-unit! grip-mode :after markdown
  :requires grip-mode
  :executable go-grip
  :config
  ;; Use go-grip for local rendering (no GitHub API needed)
  (setopt grip-command 'go-grip)
  ;; Let Appine host the preview instead of xwidget or an external browser.
  (setopt grip-preview-in-webkit nil)
  ;; Update on save for better performance
  (setopt grip-real-time-refresh nil)

  (defun backbone/grip-browse-url-a (orig-fn url)
    "Open grip preview URL in Appine when available."
    (if (backbone/appine-supported-p)
        (backbone/appine-open-url url)
      (funcall orig-fn url)))

  (advice-add 'grip--browse-url :around #'backbone/grip-browse-url-a)

  ;; Keybinding
  (define-key markdown-mode-map (kbd "C-c C-c p") #'grip-mode))

(package! csv-mode)
(package! rainbow-csv :repo "emacs-vs/rainbow-csv" :branch "master")
(package! casual :deps (csv-mode transient))

(config-unit! csv-mode
  :requires (csv-mode rainbow-csv casual)
  :config
  ;; Enable rainbow column highlighting in csv-mode
  (add-hook 'csv-mode-hook #'rainbow-csv-mode)

  ;; Casual CSV transient menu
  (keymap-set csv-mode-map "M-m" #'casual-csv-tmenu)

  ;; Disable line wrap for better CSV viewing
  (add-hook 'csv-mode-hook
            (lambda ()
              (visual-line-mode -1)
              (toggle-truncate-lines 1)))

  ;; Auto detect separator
  (add-hook 'csv-mode-hook #'csv-guess-set-separator)
  ;; Turn on field alignment
  (add-hook 'csv-mode-hook #'csv-align-mode))

(package! apheleia)

(config-unit! apheleia
  :requires apheleia
  :config
  ;; Enable format-on-save first; formatter bindings are declared in
  ;; separate units so missing executables only disable the affected modes.
  (apheleia-global-mode +1))

(config-unit! apheleia-python :after apheleia
  :requires apheleia
  :executable ruff
  :config
  ;; python
  (setf (alist-get 'python-mode apheleia-mode-alist) 'ruff)
  (setf (alist-get 'python-ts-mode apheleia-mode-alist) 'ruff))

(config-unit! apheleia-ruby :after apheleia
  :requires apheleia
  :executable rufo
  :config
  ;; ruby
  (setf (alist-get 'ruby-ts-mode apheleia-mode-alist) 'rufo))

(config-unit! apheleia-lua :after apheleia
  :requires apheleia
  :executable stylua
  :config
  ;; lua
  (setf (alist-get 'stylua apheleia-formatters) '("stylua" "--indent-type" "Spaces" "--indent-width" "2" "-")))

(config-unit! apheleia-markdown :after apheleia
  :requires apheleia
  :executable rumdl
  :config
  ;; markdown (rumdl - rust markdown linter with fmt for auto-formatting)
  (setf (alist-get 'rumdl apheleia-formatters) '("rumdl" "fmt" "--stdin"))
  (setf (alist-get 'markdown-mode apheleia-mode-alist) 'rumdl)
  (setf (alist-get 'gfm-mode apheleia-mode-alist) 'rumdl))

(config-unit! apheleia-json :after apheleia
  :requires apheleia
  :executable prettier
  :config
  ;; json - use prettier with 2-space indent for VS Code compatibility
  ;; Emacs uses js-json-mode (derived from js-mode) for JSON by default
  (setf (alist-get 'prettier-json apheleia-formatters)
        '("prettier" "--parser" "json" "--tab-width" "2"))
  (setf (alist-get 'json-mode apheleia-mode-alist) 'prettier-json)
  (setf (alist-get 'json-ts-mode apheleia-mode-alist) 'prettier-json)
  (setf (alist-get 'js-json-mode apheleia-mode-alist) 'prettier-json))

(config-unit! apheleia-nix :after apheleia
  :requires apheleia
  :config
  ;; nix - disable format-on-save
  (setf (alist-get 'nix-mode apheleia-mode-alist) nil))

;; Remap legacy modes to tree-sitter equivalents
;; Must be outside with-eval-after-load to work on first file open
;; This handles both file extensions (via auto-mode-alist defaults)
;; and shebangs (via interpreter-mode-alist defaults)
(setq major-mode-remap-alist
      '((sh-mode . bash-ts-mode)
        (css-mode . css-ts-mode)
        (js-mode . js-ts-mode)
        (js-json-mode . json-ts-mode)
        (json-mode . json-ts-mode)
        (python-mode . python-ts-mode)
        (typescript-mode . typescript-ts-mode)
        (yaml-mode . yaml-ts-mode)
        (ruby-mode . ruby-ts-mode)))

;; Modes without a built-in legacy mode need direct auto-mode-alist entries
(add-to-list 'auto-mode-alist '("\\.ya?ml\\'" . yaml-ts-mode))
(add-to-list 'auto-mode-alist '("\\(?:Dockerfile\\(?:\\..*\\)?\\|\\.[Dd]ockerfile\\)\\'" . dockerfile-ts-mode))

(config-unit! shell
  :executable (bash fish)
  :config
  (setq-default sh-file-name (executable-find "bash"))  ; for sh-mode editing
  (setq-default shell-file-name (executable-find "fish"))  ; for M-! and M-&
  (setq-default explicit-shell-file-name (executable-find "fish")))  ; for M-x shell

(package! ghostel
  :repo "dakra/ghostel"
  :branch "main"
  :files ("lisp/*.el" "etc/terminfo"))

;; Must be set before ghostel loads so missing-module installs don't prompt.
(setopt ghostel-module-auto-install 'download)

(config-unit! ghostel
  :requires ghostel
  :executable fish
  :config
  (setopt ghostel-shell (executable-find "fish"))

  ;; Ghostel buffers are terminal views, so line numbers add visual noise.
  (add-hook 'ghostel-mode-hook #'backbone/disable-line-numbers)

  ;; Use the terminal variant font.
  (add-hook 'ghostel-mode-hook
            (lambda ()
              (set (make-local-variable 'buffer-face-mode-face)
                   '(:family "BlexMono Nerd Font Mono" :height 140))
              (buffer-face-mode t)))

  ;; Keep a margin at the bottom so the prompt isn't hidden by the modeline.
  (add-hook 'ghostel-mode-hook
            (lambda () (setq-local scroll-margin 3))))

(package! eat)
;; (package! cli2eli :repo "nohzafk/cli2eli" :branch "main")
(package! cli2eli :local "~/projects/cli2eli")

(config-unit! cli2eli
  :requires (cli2eli eat)
  :config

  ;; Use eat as terminal backend (recommended)
  (setopt cli2eli-terminal-backend 'eat)
  (setopt cli2eli-output-buffer-display-option #'display-buffer-other-frame)

  ;; Command palette keybinding
  (global-set-key (kbd "<f7>") #'cli2eli-run)

  (setq clis-dir (expand-file-name "clis/" emacs-backbone-user-directory))
  (let ((quickrun-file (expand-file-name "cli-quickrun.json" clis-dir))
        (transform-file (expand-file-name "cli-transform.json" clis-dir)))
    (when (file-exists-p quickrun-file)
      (cli2eli-load-tool quickrun-file))
    (when (file-exists-p transform-file)
      (cli2eli-load-tool transform-file))))

(package! shell-maker :repo "xenodium/shell-maker" :branch "main")
(package! acp :repo "xenodium/acp.el" :branch "main" :deps shell-maker)
(package! agent-shell :repo "xenodium/agent-shell" :branch "main" :deps (shell-maker acp))
(package! agent-shell-manager
  :repo "jethrokuan/agent-shell-manager"
  :branch "main"
  :deps agent-shell)
(package! agent-shell-darwin-notifications
  :repo "nohzafk/agent-shell-darwin-notifications"
  :branch "main")
(package! agent-shell-ediff
  :repo "cassandracomar/agent-shell-ediff"
  :branch "main"
  :deps agent-shell)
(package! visual-fill-column)

(config-unit! agent-shell
  :requires (agent-shell agent-shell-darwin-notifications agent-shell-manager transient)
  :executable terminal-notifier
  :config
  ;; Claude Code configuration
  ;; Set ANTHROPIC_API_KEY, and optionally ANTHROPIC_BASE_URL,
  ;; in your environment.
  (setopt agent-shell-anthropic-claude-acp-command
          '("claude-agent-acp" "--model" "claude-opus-4-6"))
  (let ((anthropic-api-key (getenv "ANTHROPIC_API_KEY"))
        (anthropic-base-url (getenv "ANTHROPIC_BASE_URL")))
    (cond
     (anthropic-api-key
      (setopt agent-shell-anthropic-claude-environment
              (when anthropic-base-url
                (agent-shell-make-environment-variables "ANTHROPIC_BASE_URL" anthropic-base-url)))
      (setopt agent-shell-anthropic-authentication
              (agent-shell-anthropic-make-authentication :api-key anthropic-api-key)))
     (t
      (setopt agent-shell-anthropic-claude-environment nil)
      (setopt agent-shell-anthropic-authentication
              (agent-shell-anthropic-make-authentication :login t)))))

  (add-hook 'agent-shell-mode-hook #'backbone/disable-line-numbers)
  (add-hook 'agent-shell-mode-hook
            (lambda ()
              (setq-local agent-shell-darwin-notify-current-buffer nil)))

  (when (eq system-type 'darwin)
    (add-hook 'agent-shell-mode-hook #'agent-shell-darwin-notifications-setup))

  (defun backbone/agent-shell-expand-fragment-if-collapsed (buffer namespace-id block-id)
    "Expand the fragment in BUFFER identified by NAMESPACE-ID and BLOCK-ID."
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (let ((qualified-id (format "%s-%s" namespace-id block-id)))
            (when-let ((match (text-property-search-backward
                               'agent-shell-ui-state nil
                               (lambda (_ state)
                                 (equal (map-elt state :qualified-id) qualified-id))
                               t)))
              (goto-char (prop-match-beginning match))
              (when-let ((state (get-text-property (point) 'agent-shell-ui-state)))
                (when (map-elt state :collapsed)
                  (agent-shell-ui-toggle-fragment-at-point)))))))))

  (defun backbone/agent-shell-auto-expand-edit-fragment-a (&rest args)
    "Keep edit tool-call fragments expanded in agent-shell buffers."
    (when-let* ((state (plist-get args :state))
                (block-id (plist-get args :block-id))
                (namespace-id (or (plist-get args :namespace-id)
                                  (map-elt state :request-count)))
                (shell-buffer (map-elt state :buffer))
                ((equal (map-nested-elt state `(:tool-calls ,block-id :kind)) "edit")))
      (backbone/agent-shell-expand-fragment-if-collapsed shell-buffer namespace-id block-id)
      (when-let ((viewport-buffer (agent-shell-viewport--buffer
                                   :shell-buffer shell-buffer
                                   :existing-only t)))
        (backbone/agent-shell-expand-fragment-if-collapsed viewport-buffer namespace-id block-id))))

  (advice-add 'agent-shell--update-fragment :after #'backbone/agent-shell-auto-expand-edit-fragment-a)

  (transient-define-prefix my/agent-shell-menu ()
    "Agent Shell commands"
    [["Agents"
      ("c" "Claude Code" agent-shell-anthropic-start-claude-code)
      ("o" "OpenAI Codex" agent-shell-openai-start-codex)]
     ["Manage"
      ("m" "Manager" agent-shell-manager-toggle)]])

  (keymap-set global-map "C-c a" #'my/agent-shell-menu))

(config-unit! agent-shell-consult-snapfile :after agent-shell
  :requires (agent-shell consult consult-snapfile)
  :config
  (defun backbone/agent-shell-mention-root ()
    "Return the root directory for @mentions in the current agent-shell buffer."
    (expand-file-name default-directory))

  (defun backbone/agent-shell-fuzzy-insert-file ()
    "Insert a file reference using consult-snapfile fuzzy matching.
On cancel, inserts bare @ for manual typing."
    (interactive)
    (let* ((root (backbone/agent-shell-mention-root))
           (default-directory root)
           (prompt (format "@ Path [%s]: " (abbreviate-file-name root)))
           (selected (condition-case nil
                         (consult-snapfile-read
                          :cwd root
                          :mode 'paths
                          :prompt prompt
                          :history 'file-name-history
                          :require-match t)
                       (quit nil))))
      (if selected
          (let ((path (substring-no-properties selected)))
            (insert "@" path)
            (unless (string-suffix-p "/" path)
              (insert " ")))
        (insert "@"))))

  (keymap-set agent-shell-mode-map "@" #'backbone/agent-shell-fuzzy-insert-file)
  (keymap-set agent-shell-viewport-edit-mode-map "@" #'backbone/agent-shell-fuzzy-insert-file)

  (defun backbone/agent-shell-buffer-word-candidates (prefix)
    "Return words in the current buffer that start with PREFIX."
    (let ((seen (make-hash-table :test #'equal))
          candidates)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "\\(?:\\sw\\|\\s_\\)+" nil t)
          (let ((word (match-string-no-properties 0)))
            (when (and (string-prefix-p prefix word)
                       (> (length word) (length prefix))
                       (not (equal word prefix))
                       (not (gethash word seen)))
              (puthash word t seen)
              (push word candidates)))))
      (sort candidates #'string-lessp)))

  (defun backbone/agent-shell-buffer-word-capf ()
    "Complete the symbol at point from words already present in this buffer."
    (when-let ((bounds (bounds-of-thing-at-point 'symbol)))
      (list (car bounds)
            (cdr bounds)
            (completion-table-dynamic #'backbone/agent-shell-buffer-word-candidates)
            :exclusive 'no)))

  (defun backbone/agent-shell-setup-fuzzy-completion ()
    "Use consult completion with buffer-word CAPF in agent-shell."
    (setq-local completion-in-region-function
                #'consult-completion-in-region)
    (add-hook 'completion-at-point-functions #'backbone/agent-shell-buffer-word-capf nil t))
  (add-hook 'agent-shell-mode-hook #'backbone/agent-shell-setup-fuzzy-completion)
  (add-hook 'agent-shell-viewport-edit-mode-hook #'backbone/agent-shell-setup-fuzzy-completion))

(config-unit! agent-shell-openai-codex :after agent-shell
  :requires agent-shell
  :executable codex-acp
  :config
  ;; Set OPENAI_API_KEY or CODEX_API_KEY, and optionally OPENAI_BASE_URL,
  ;; in your environment.
  (let ((openai-api-key (getenv "OPENAI_API_KEY"))
        (codex-api-key (getenv "CODEX_API_KEY"))
        (openai-base-url (getenv "OPENAI_BASE_URL")))
    (setopt agent-shell-openai-codex-acp-command
            (append '("codex-acp")
                    (when openai-base-url
                      (list "--config"
                            (format "openai_base_url=%s" openai-base-url)))))

    (cond
     (codex-api-key
      (setopt agent-shell-openai-authentication
              (agent-shell-openai-make-authentication :codex-api-key codex-api-key)))
     (openai-api-key
      (setopt agent-shell-openai-authentication
              (agent-shell-openai-make-authentication :api-key openai-api-key)))
     (t
      (setopt agent-shell-openai-authentication
              (agent-shell-openai-make-authentication :login t))))))

(config-unit! agent-shell-jira-mcp :after agent-shell
  :requires agent-shell
  :env JIRA_API_TOKEN
  :executable uvx
  :config
  (setopt agent-shell-mcp-servers
          '(((name . "mcp-atlassian")
             (command . "uvx")
             (args . ("mcp-atlassian"))
             (env . (((name . "JIRA_URL")
                      (value . "https://new-talpasolutions.atlassian.net"))
                     ((name . "JIRA_USERNAME")
                      (value . "randall@talpa-solutions.com"))
                     ((name . "JIRA_API_TOKEN")
                      (value . (lambda ()
                                 (getenv "JIRA_API_TOKEN"))))))))))

(config-unit! agent-shell-beautify :after agent-shell
  :requires (agent-shell visual-fill-column)
  :config
  (setopt agent-shell-header-style 'text)
  (setopt agent-shell-show-context-usage-indicator 'detailed)
  (setopt agent-shell-show-session-id nil)
  (setopt agent-shell-thought-process-expand-by-default nil)

  (defun backbone/agent-shell-beautify ()
    "Apply lightweight layout tweaks to agent-shell buffers."
    (setq-local buffer-face-mode-face
                '(:family "BlexMono Nerd Font Mono" :height 140))
    (buffer-face-mode 1)
    (visual-line-mode 1)
    (setq-local visual-fill-column-width 130
                visual-fill-column-center-text t)
    (visual-fill-column-mode 1)
    (setq-local scroll-conservatively 101))

  (add-hook 'agent-shell-mode-hook #'backbone/agent-shell-beautify))

(config-unit! agent-shell-ediff :after agent-shell
  :requires agent-shell-ediff
  :config
  (setopt agent-shell-ediff-quick-quit t)
  (agent-shell-ediff-mode 1))

(config-unit! agent-shell-manager :after agent-shell
  :requires agent-shell-manager
  :config
  (setopt agent-shell-manager-side 'bottom))

(require 'org-tempo)

(config-unit! org
  :config
  (remove-hook 'org-mode-hook #'+literate-enable-recompile-h)

  ;; Prevent typing an underscore from becoming a subscript
  (setopt org-use-sub-superscripts '{}
          org-export-with-sub-superscripts nil))

(package! org-modern)

(config-unit! org-modern :after org
  :requires org-modern
  :config

  (setopt
   ;; Edit settings
   org-auto-align-tags nil
   org-tags-column 0
   org-catch-invisible-edits 'show-and-error
   org-special-ctrl-a/e t
   org-insert-heading-respect-content t

   ;; Org styling, hide markup etc.
   org-hide-emphasis-markers t
   org-pretty-entities t)

  ;; Ellipsis styling
  (setopt org-ellipsis "…")
  (set-face-attribute 'org-ellipsis nil :inherit 'default :box nil)

  (global-org-modern-mode))

(package! org-modern-indent :repo "jdtsmith/org-modern-indent" :branch "main")

(config-unit! org-modern-indent :after org-modern
  :requires org-modern-indent
  :config
  (add-hook 'org-mode-hook #'org-modern-indent-mode 90))

(config-unit! org-latex-preview :after org
  :executable dvisvgm
  :config
  ;; Use dvisvgm for better quality previews
  (setopt org-preview-latex-default-process 'dvisvgm)
  ;; Auto-start with LaTeX preview enabled
  (setopt org-startup-with-latex-preview t)
  ;; Auto-start with inline images displayed
  (setopt org-startup-with-inline-images t))

(package! org-fragtog)

(config-unit! org-fragtog :after org
  :requires org-fragtog
  :config
  ;; Automatically toggle LaTeX fragments as cursor moves in/out
  (add-hook 'org-mode-hook #'org-fragtog-mode))

(config-unit! org-babel-python-pytest :after org
  :executable pytest
  :config
  (defun org-babel-execute:python-with-pytest (body params)
    "Execute a python source block with pytest if :pytest is specified.
Uses :timeout parameter (default 3 seconds) with pytest-timeout package."
    (if (assq :pytest params)
        (let* ((temporary-file-directory default-directory)
               (temp-file (make-temp-file "pytest-" nil ".py"))
               (timeout (or (cdr (assq :timeout params)) "3"))
               (pytest-command (format "pytest -v -s --timeout=%s %s"
                                       (shell-quote-argument timeout)
                                       (shell-quote-argument temp-file))))
          (with-temp-file temp-file
            (insert body))
          (unwind-protect
              (org-babel-eval pytest-command "")
            (delete-file temp-file)))
      (org-babel-execute:python-default body params)))

  ;; Override default Python execution with pytest-aware version
  (advice-add 'org-babel-execute:python :override #'org-babel-execute:python-with-pytest))

(config-unit! leetcode-templates :after org
  :config
  (require 'tempo)

  (defun get-formatted-filename ()
    "Get the current buffer's filename without extension, replacing dashes with spaces."
    (let ((filename (file-name-sans-extension (buffer-name))))
      (replace-regexp-in-string "-" " " filename)))

  (tempo-define-template
   "leetcode-solution"
   '("* Problem: " (get-formatted-filename)
     n
     p
     n
     "* Solution"
     n
     "#+begin_src python :pytest"
     n
     "#+end_src"
     n
     "* Note"
     n
     "* Reflection"
     "
Do an analysis for the problem and solutions.

What are the key takeaways and lessons from this problem?

What techniques can I learn from it to apply to other problems?
"))

  (defun insert-leetcode-solution ()
    "Insert leetcode solution template at point."
    (interactive)
    (tempo-template-leetcode-solution))

  ;; Cleanup utilities for leetcode files
  (defun remove-consecutive-blank-lines ()
    "Remove multiple consecutive blank lines in the buffer, skipping src blocks."
    (interactive)
    (save-excursion
      (goto-char (point-min))
      (let ((in-src-block nil))
        (while (not (eobp))
          (cond
           ((looking-at "^#\\+begin_src")
            (setq in-src-block t)
            (forward-line))
           ((looking-at "^#\\+end_src")
            (setq in-src-block nil)
            (forward-line))
           ((and (not in-src-block)
                 (looking-at "\n\\{3,\\}"))
            (replace-match "\n\n"))
           (t (forward-line)))))))

  (defun format-leetcode-solution ()
    "Format the current buffer by removing consecutive blank lines,
trailing whitespaces, and ensuring a newline at the end of the file."
    (interactive)
    (remove-consecutive-blank-lines)
    (delete-trailing-whitespace)
    (save-excursion
      (goto-char (point-max))
      (unless (looking-back "\n" 1)
        (newline)))))

(package! ob-mermaid)

(config-unit! org-mermaid :after org
  :requires ob-mermaid
  :config
  ;; Add mermaid to babel load languages
  (add-to-list 'org-babel-load-languages '(mermaid . t)))

;; Keep which-key-mode enabled for discoverability of other keybindings
(which-key-mode)

(global-set-key [f8] #'delete-frame)

(package! imenu-list)

(config-unit! jump-keymap :after minibuffer-settings
  :requires (consult avy transient imenu-list consult-snapfile)
  :config
  (transient-define-prefix my/jump-menu ()
    "Jump and navigation commands"
    [["Code Navigation"
      ("i" "imenu" consult-imenu)
      ("o" "outline" consult-outline)
      ("e" "errors" consult-flymake)
      ("I" "imenu list" imenu-list-smart-toggle)]
     ["File Navigation"
      ("d" "dired" dired-jump)]
     ["Avy Jump"
      ("j" "jump to char" avy-goto-char-2)
      ("l" "jump to line" avy-goto-line)]])

  (keymap-set global-map "C-c j" #'my/jump-menu))

(config-unit! search-keymap
  :requires transient
  :config
  (transient-define-prefix my/search-menu ()
    "Search commands"
    [["Search in Buffer"
      ("s" "consult line" consult-line)]
     ["Search in Project"
      ("l" "snapfile" consult-snapfile)
      ("p" "consult ripgrep" consult-ripgrep)
      ("r" "rg menu" rg-menu)]])

  (keymap-set global-map "C-c s" #'my/search-menu))

(config-unit! open-keymap
  :requires transient
  :config
  (transient-define-prefix my/open-menu ()
    "Open commands"
    ["Open"
     ("A" "appine menu" my/appine-menu)
     ("a" "appine window" backbone/appine)
     ("f" "appine file" backbone/appine-open-file)
     ("t" "ghostel" ghostel)
     ("p" "thing at point" embark-dwim)
     ("r" "recent files" consult-recent-file)
     ("s" "scratch" (lambda () (interactive) (pop-to-buffer "*scratch*")))
     ("u" "appine URL" backbone/appine-open-url)
     ("e" "config.org" (lambda () (interactive)
                         (find-file (expand-file-name "config.org" emacs-backbone-user-directory))))])

  (keymap-set global-map "C-c o" #'my/open-menu))

(config-unit! quit-keymap
  :requires (transient)
  :config
  (transient-define-prefix my/quit-menu ()
    "Quit and restart commands"
    ["Quit"
     ("q" "quit Emacs" save-buffers-kill-emacs)
     ("r" "restart Emacs" backbone/restart-and-restore-suffix)])

  (keymap-set global-map "C-c q" #'my/quit-menu))

(package! key-chord)

(config-unit! key-chord
  :requires key-chord
  :config
  (setopt key-chord-two-keys-delay 0.08)
  (key-chord-mode 1)
  (key-chord-define-global "jk" #'execute-extended-command)

  (dolist (hook '(ghostel-mode-hook))
    (add-hook hook (lambda () (key-chord-mode -1)))))
