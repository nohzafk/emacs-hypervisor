;;; emacs-hypervisor-markdown-mermaid.el --- Markdown Mermaid extension UI -*- lexical-binding: t; -*-

(require 'emacs-hypervisor-extensions)

(defgroup emacs-hypervisor-markdown-mermaid nil
  "Markdown Mermaid rendering through Hypervisor extensions."
  :group 'emacs-hypervisor-extensions)

(defcustom emacs-hypervisor-markdown-mermaid-auto-refresh-delay 0.8
  "Seconds to wait after buffer edits before refreshing Mermaid renders.
Set to nil to disable automatic refresh while editing."
  :type '(choice (const :tag "Disabled" nil)
                 (number :tag "Seconds"))
  :group 'emacs-hypervisor-markdown-mermaid)

(defcustom emacs-hypervisor-markdown-mermaid-render-style :auto
  "Preferred Mermaid render style.
When set to `:auto', use SVG images when supported by this Emacs build and
fall back to ASCII text otherwise."
  :type '(choice (const :tag "Auto" :auto)
                 (const :tag "SVG" :svg)
                 (const :tag "ASCII" :ascii))
  :group 'emacs-hypervisor-markdown-mermaid)

(defvar-local emacs-hypervisor-markdown-mermaid--overlays nil)
(defvar-local emacs-hypervisor-markdown-mermaid--refresh-timer nil)

(defvar emacs-hypervisor-markdown-mermaid-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'emacs-hypervisor-markdown-mermaid-refresh)
    map)
  "Keymap for `emacs-hypervisor-markdown-mermaid-mode'.")

(defun emacs-hypervisor-markdown-mermaid--cancel-refresh-timer ()
  "Cancel any pending Mermaid refresh timer."
  (when emacs-hypervisor-markdown-mermaid--refresh-timer
    (when (timerp emacs-hypervisor-markdown-mermaid--refresh-timer)
      (cancel-timer emacs-hypervisor-markdown-mermaid--refresh-timer))
    (setq emacs-hypervisor-markdown-mermaid--refresh-timer nil)))

(defun emacs-hypervisor-markdown-mermaid--visible-width ()
  "Return the visible Mermaid ASCII width in text columns."
  (let ((window (or (get-buffer-window (current-buffer) t)
                    (and (eq (window-buffer (selected-window))
                             (current-buffer))
                         (selected-window)))))
    (max 20
         (if window
             (window-text-width window)
           (window-body-width)))))

(defun emacs-hypervisor-markdown-mermaid--viewport-width (_pos)
  "Return the Mermaid ASCII viewport width in columns.
The rendered overlay starts on a fresh line, so use the visible text area
width rather than the source position's current column."
  (emacs-hypervisor-markdown-mermaid--visible-width))

(defun emacs-hypervisor-markdown-mermaid-extension-settings ()
  "Return Markdown Mermaid settings for Elle startup."
  (list
   :mermaid-enabled (emacs-hypervisor-extension-enabled-p "mermaid")))

(emacs-hypervisor-register-extension-settings
 #'emacs-hypervisor-markdown-mermaid-extension-settings)

(defun emacs-hypervisor-markdown-mermaid--response-ok-p (response)
  "Return non-nil when RESPONSE is an Elle success payload."
  (let ((ok (plist-get response :ok)))
    (and ok (not (eq ok 'false)))))

(defun emacs-hypervisor-markdown-mermaid--render-style ()
  "Return the render style to request from Elle."
  (let ((style emacs-hypervisor-markdown-mermaid-render-style))
    (cond
     ((or (eq style :auto) (eq style 'auto) (equal style "auto"))
      (if (image-type-available-p 'svg) :svg :ascii))
     ((or (eq style :svg) (eq style 'svg) (equal style "svg"))
      :svg)
     ((or (eq style :ascii) (eq style 'ascii) (equal style "ascii"))
      :ascii)
     (t
      :ascii))))

(defun emacs-hypervisor-markdown-mermaid--source-blocks ()
  "Return Mermaid fenced source blocks in the current buffer.
Each result has the shape (START END SOURCE-START SOURCE-END SOURCE)."
  (save-excursion
    (goto-char (point-min))
    (let (blocks)
      (while (re-search-forward "^[ \t]*```[ \t]*mermaid[^\n]*\n" nil t)
        (let ((block-start (match-beginning 0))
              (source-start (point)))
          (when (re-search-forward "^[ \t]*```[ \t]*$" nil t)
            (let ((source-end (match-beginning 0))
                  (block-end (match-end 0)))
              (push (list block-start block-end source-start source-end
                          (buffer-substring-no-properties source-start source-end))
                    blocks)))))
      (nreverse blocks))))

(defun emacs-hypervisor-markdown-mermaid-clear-buffer ()
  "Remove Mermaid render overlays from the current buffer."
  (interactive)
  (emacs-hypervisor-markdown-mermaid--cancel-refresh-timer)
  (mapc #'delete-overlay emacs-hypervisor-markdown-mermaid--overlays)
  (setq emacs-hypervisor-markdown-mermaid--overlays nil))

(defun emacs-hypervisor-markdown-mermaid--insert-overlay (pos display)
  "Insert a Mermaid render overlay at POS with DISPLAY."
  (let ((overlay (make-overlay pos pos nil t nil)))
    (overlay-put overlay 'emacs-hypervisor-markdown-mermaid t)
    (overlay-put overlay 'after-string display)
    (push overlay emacs-hypervisor-markdown-mermaid--overlays)
    overlay))

(defun emacs-hypervisor-markdown-mermaid--display-for-response (response)
  "Return an overlay display string or image from RESPONSE."
  (pcase (plist-get response :kind)
    (:image
     (let ((mime (plist-get response :mime))
           (svg (plist-get response :svg)))
       (if (and (equal mime "image/svg+xml")
                (stringp svg)
                (image-type-available-p 'svg))
           (concat "\n"
                   (propertize " " 'display
                               (create-image svg 'svg t :ascent 'center))
                   "\n")
         "\n[Hypervisor Mermaid] unsupported image response\n")))
    (:text
     (concat "\n" (or (plist-get response :text) "") "\n"))
    (_
     (concat "\n[Hypervisor Mermaid] unsupported response\n"))))

(defun emacs-hypervisor-markdown-mermaid--render-block (block)
  "Render one Mermaid BLOCK and add its overlay."
  (let* ((block-end (nth 1 block))
         (source (nth 4 block))
         (response
          (emacs-hypervisor-extension-call
           :mermaid
           :render
           (list :source source
                 :style (emacs-hypervisor-markdown-mermaid--render-style)
                 :viewport (list :width
                                 (emacs-hypervisor-markdown-mermaid--viewport-width block-end)))
           10)))
    (if (emacs-hypervisor-markdown-mermaid--response-ok-p response)
        (emacs-hypervisor-markdown-mermaid--insert-overlay
         block-end
         (emacs-hypervisor-markdown-mermaid--display-for-response response))
      (emacs-hypervisor-markdown-mermaid--insert-overlay
       block-end
       (format "\n[Hypervisor Mermaid] %s\n"
               (or (plist-get response :message) "render failed"))))))

(defun emacs-hypervisor-markdown-mermaid-render-buffer ()
  "Render Mermaid fences in the current Markdown buffer."
  (interactive)
  (unless (emacs-hypervisor-extension-enabled-p "mermaid")
    (user-error "Mermaid extension is disabled"))
  (emacs-hypervisor-markdown-mermaid--cancel-refresh-timer)
  (emacs-hypervisor-markdown-mermaid-clear-buffer)
  (dolist (block (emacs-hypervisor-markdown-mermaid--source-blocks))
    (emacs-hypervisor-markdown-mermaid--render-block block)))

(defun emacs-hypervisor-markdown-mermaid-refresh ()
  "Refresh Mermaid renders in the current buffer."
  (interactive)
  (emacs-hypervisor-markdown-mermaid-render-buffer))

(defun emacs-hypervisor-markdown-mermaid--auto-refresh-buffer (buffer)
  "Refresh Mermaid renders in BUFFER when the mode is still active."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacs-hypervisor-markdown-mermaid--refresh-timer nil)
      (when emacs-hypervisor-markdown-mermaid-mode
        (ignore-errors
          (emacs-hypervisor-markdown-mermaid-render-buffer))))))

(defun emacs-hypervisor-markdown-mermaid--schedule-refresh (&rest _change)
  "Schedule a debounced Mermaid refresh after buffer edits."
  (when (and emacs-hypervisor-markdown-mermaid-mode
             emacs-hypervisor-markdown-mermaid-auto-refresh-delay)
    (emacs-hypervisor-markdown-mermaid--cancel-refresh-timer)
    (setq emacs-hypervisor-markdown-mermaid--refresh-timer
          (run-with-idle-timer
           emacs-hypervisor-markdown-mermaid-auto-refresh-delay
           nil
           #'emacs-hypervisor-markdown-mermaid--auto-refresh-buffer
           (current-buffer)))))

(define-minor-mode emacs-hypervisor-markdown-mermaid-mode
  "Render Mermaid code fences through the live Elle Hypervisor."
  :lighter " HV-Mermaid"
  (if emacs-hypervisor-markdown-mermaid-mode
      (progn
        (add-hook 'after-change-functions
                  #'emacs-hypervisor-markdown-mermaid--schedule-refresh
                  nil
                  t)
        (when (emacs-hypervisor-extension-enabled-p "mermaid")
          (emacs-hypervisor-markdown-mermaid-render-buffer)))
    (remove-hook 'after-change-functions
                 #'emacs-hypervisor-markdown-mermaid--schedule-refresh
                 t)
    (emacs-hypervisor-markdown-mermaid-clear-buffer)))

(defun emacs-hypervisor-markdown-mermaid-maybe-enable ()
  "Enable Mermaid rendering in Markdown buffers when configured."
  (when (emacs-hypervisor-extension-enabled-p "mermaid")
    (emacs-hypervisor-markdown-mermaid-mode 1)))

(defun emacs-hypervisor-markdown-mermaid-install-hooks ()
  "Install autoload-safe Markdown Mermaid hooks."
  (dolist (hook '(markdown-mode-hook markdown-ts-mode-hook gfm-mode-hook))
    (add-hook hook #'emacs-hypervisor-markdown-mermaid-maybe-enable)))

(emacs-hypervisor-markdown-mermaid-install-hooks)

(provide 'emacs-hypervisor-markdown-mermaid)
