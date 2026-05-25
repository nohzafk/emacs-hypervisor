;;; emacs-hypervisor-markdown-mermaid.el --- Markdown Mermaid extension UI -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-extensions)
(require 'image-mode)

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

(defcustom emacs-hypervisor-markdown-mermaid-preview-max-width 'fill-column
  "Maximum inline SVG preview width.
Allowed values are `fill-column', `window', an integer pixel width, or nil for
no maximum."
  :type '(choice (const :tag "Fill column" fill-column)
                 (const :tag "Window width" window)
                 (integer :tag "Pixel width")
                 (const :tag "No limit" nil))
  :group 'emacs-hypervisor-markdown-mermaid)

(defcustom emacs-hypervisor-markdown-mermaid-preview-max-height 0.30
  "Maximum inline SVG preview height.
A float means a fraction of the current window pixel height. An integer means
pixels. Nil disables height bounding."
  :type '(choice (float :tag "Window fraction")
                 (integer :tag "Pixel height")
                 (const :tag "No limit" nil))
  :group 'emacs-hypervisor-markdown-mermaid)

(defcustom emacs-hypervisor-markdown-mermaid-viewer-display-action 'other-window
  "How to display the full Mermaid image viewer."
  :type '(choice (const :tag "Other window" other-window)
                 (const :tag "Side window" side-window)
                 (const :tag "Frame" frame))
  :group 'emacs-hypervisor-markdown-mermaid)

(defcustom emacs-hypervisor-markdown-mermaid-viewer-fit-on-open t
  "When non-nil, fit the opened viewer image to its window."
  :type 'boolean
  :group 'emacs-hypervisor-markdown-mermaid)

(defcustom emacs-hypervisor-markdown-mermaid-preview-use-slices nil
  "Whether to slice large inline previews to reduce redisplay flicker.
This should remain nil unless the default 45% window-height preview cap still
flickers during manual verification."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "Always" t))
  :group 'emacs-hypervisor-markdown-mermaid)

(defvar-local emacs-hypervisor-markdown-mermaid--overlays nil)
(defvar-local emacs-hypervisor-markdown-mermaid--refresh-timer nil)

(defvar-local emacs-hypervisor-markdown-mermaid-viewer-render nil)
(defvar-local emacs-hypervisor-markdown-mermaid-viewer-source-buffer nil)
(defvar-local emacs-hypervisor-markdown-mermaid-viewer-cache-file nil)

(defvar emacs-hypervisor-markdown-mermaid-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'emacs-hypervisor-markdown-mermaid-refresh)
    map)
  "Keymap for `emacs-hypervisor-markdown-mermaid-mode'.")

(defvar emacs-hypervisor-markdown-mermaid-preview-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map image-map)
    (define-key map (kbd "RET")
                #'emacs-hypervisor-markdown-mermaid-open-viewer-at-point)
    (define-key map [mouse-1]
                #'emacs-hypervisor-markdown-mermaid-open-viewer-at-point)
    map)
  "Keymap for inline Mermaid preview images.")

(defvar emacs-hypervisor-markdown-mermaid-viewer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map image-mode-map)
    (define-key map (kbd "g")
                #'emacs-hypervisor-markdown-mermaid-refresh-viewer)
    (define-key map (kbd "q")
                #'emacs-hypervisor-markdown-mermaid-close-viewer)
    (define-key map (kbd "+")
                #'emacs-hypervisor-markdown-mermaid-viewer-zoom-in)
    (define-key map (kbd "=")
                #'emacs-hypervisor-markdown-mermaid-viewer-zoom-in)
    (define-key map (kbd "-")
                #'emacs-hypervisor-markdown-mermaid-viewer-zoom-out)
    (define-key map (kbd "0")
                #'emacs-hypervisor-markdown-mermaid-viewer-original-size)
    (define-key map (kbd "w")
                #'emacs-hypervisor-markdown-mermaid-viewer-fit-width)
    (define-key map (kbd "f")
                #'emacs-hypervisor-markdown-mermaid-viewer-fit-window)
    (define-key map (kbd "RET")
                #'emacs-hypervisor-markdown-mermaid-jump-to-source)
    map)
  "Keymap for Mermaid viewer buffers.")

(define-derived-mode emacs-hypervisor-markdown-mermaid-viewer-mode image-mode
  "HV-Mermaid-Image"
  "Major mode for full-size Hypervisor Mermaid image buffers.")

(defconst emacs-hypervisor-markdown-mermaid--viewer-help
  "Mermaid viewer: +/= zoom in, - zoom out, 0 original, w fit width, f fit window, g refresh, RET source, q quit"
  "Header line text for Mermaid viewer buffers.")

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

(defun emacs-hypervisor-markdown-mermaid--buffer-window ()
  "Return a live window displaying the current buffer, when available."
  (or (get-buffer-window (current-buffer) t)
      (and (eq (window-buffer (selected-window))
               (current-buffer))
           (selected-window))))

(defun emacs-hypervisor-markdown-mermaid--window-pixel-width ()
  "Return current buffer window width in pixels."
  (let ((window (emacs-hypervisor-markdown-mermaid--buffer-window)))
    (if window
        (window-pixel-width window)
      (frame-pixel-width))))

(defun emacs-hypervisor-markdown-mermaid--window-pixel-height ()
  "Return current buffer window height in pixels."
  (let ((window (emacs-hypervisor-markdown-mermaid--buffer-window)))
    (if window
        (window-pixel-height window)
      (frame-pixel-height))))

(defun emacs-hypervisor-markdown-mermaid--preview-bound (value axis)
  "Resolve preview bound VALUE for AXIS.
AXIS is either `width' or `height'."
  (cond
   ((null value) nil)
   ((integerp value) value)
   ((and (eq axis 'width) (eq value 'fill-column))
    (* fill-column (frame-char-width (selected-frame))))
   ((and (eq axis 'width) (eq value 'window))
    (emacs-hypervisor-markdown-mermaid--window-pixel-width))
   ((and (eq axis 'height) (floatp value))
    (max 1 (round (* value
                     (emacs-hypervisor-markdown-mermaid--window-pixel-height)))))
   (t nil)))

(defun emacs-hypervisor-markdown-mermaid--preview-max-width ()
  "Return the inline preview maximum width in pixels, or nil."
  (emacs-hypervisor-markdown-mermaid--preview-bound
   emacs-hypervisor-markdown-mermaid-preview-max-width
   'width))

(defun emacs-hypervisor-markdown-mermaid--preview-max-height ()
  "Return the inline preview maximum height in pixels, or nil."
  (emacs-hypervisor-markdown-mermaid--preview-bound
   emacs-hypervisor-markdown-mermaid-preview-max-height
   'height))

(defun emacs-hypervisor-markdown-mermaid--viewport-width (_pos)
  "Return the Mermaid ASCII viewport width in columns.
The rendered overlay starts on a fresh line, so use the visible text area
width rather than the source position's current column."
  (emacs-hypervisor-markdown-mermaid--visible-width))

(defun emacs-hypervisor-markdown-mermaid--plist-delete (plist property)
  "Return PLIST without PROPERTY and its value."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (eq key property)
          (setq result (plist-put result key value)))))
    result))

(defun emacs-hypervisor-markdown-mermaid--create-preview-image (svg)
  "Create a bounded inline SVG preview image for SVG."
  (let* ((max-width
          (emacs-hypervisor-markdown-mermaid--preview-max-width))
         (max-height
          (emacs-hypervisor-markdown-mermaid--preview-max-height))
         (properties (list :ascent 'center
                           :scale 1
                           :keymap emacs-hypervisor-markdown-mermaid-preview-map
                           :max-width max-width
                           :max-height max-height)))
    (condition-case nil
        (apply #'create-image svg 'svg t properties)
      (error
       (apply #'create-image
              svg
              'svg
              t
              (emacs-hypervisor-markdown-mermaid--plist-delete
               properties
               :max-height))))))

(defun emacs-hypervisor-markdown-mermaid--render-object (response block)
  "Normalize a successful image RESPONSE for Mermaid BLOCK."
  (let ((source-buffer (current-buffer))
        (source-buffer-file (buffer-file-name))
        (source (nth 4 block))
        (block-start (nth 0 block))
        (block-end (nth 1 block))
        (svg (plist-get response :svg)))
    (list :kind 'image
          :mime (plist-get response :mime)
          :svg svg
          :source source
          :block-start block-start
          :block-end block-end
          :source-start (nth 2 block)
          :source-end (nth 3 block)
          :source-buffer source-buffer
          :source-buffer-name (buffer-name source-buffer)
          :source-buffer-file source-buffer-file
          :rendered-at (float-time)
          :preview-image
          (and (stringp svg)
               (image-type-available-p 'svg)
               (emacs-hypervisor-markdown-mermaid--create-preview-image svg))
          :cache-file nil)))

(defun emacs-hypervisor-markdown-mermaid--cache-directory ()
  "Return the Hypervisor Mermaid SVG cache directory."
  (let ((directory
         (expand-file-name "emacs-hypervisor/mermaid/" temporary-file-directory)))
    (make-directory directory t)
    directory))

(defun emacs-hypervisor-markdown-mermaid--safe-cache-part (value)
  "Return a filesystem-safe cache name part for VALUE."
  (replace-regexp-in-string
   "-+"
   "-"
   (replace-regexp-in-string
    "[^[:alnum:]]+"
    "-"
    (downcase (or value "buffer")))))

(defun emacs-hypervisor-markdown-mermaid--cache-file-name (render)
  "Return a cache file path for RENDER."
  (let* ((source-name
          (or (plist-get render :source-buffer-file)
              (plist-get render :source-buffer-name)
              "buffer"))
         (line (with-current-buffer (plist-get render :source-buffer)
                 (line-number-at-pos (plist-get render :block-start))))
         (hash-source (secure-hash 'sha1 source-name))
         (hash-content (secure-hash 'sha1 (or (plist-get render :svg) "")))
         (name (format "%s-line-%d-%s-%s.svg"
                       (emacs-hypervisor-markdown-mermaid--safe-cache-part
                        (file-name-base source-name))
                       line
                       (substring hash-source 0 8)
                       (substring hash-content 0 8))))
    (expand-file-name name
                      (emacs-hypervisor-markdown-mermaid--cache-directory))))

(defun emacs-hypervisor-markdown-mermaid--write-cache-file (render)
  "Write RENDER SVG to its cache file and return the updated render object."
  (let ((svg (plist-get render :svg))
        (cache-file (or (plist-get render :cache-file)
                        (emacs-hypervisor-markdown-mermaid--cache-file-name
                         render))))
    (unless (stringp svg)
      (user-error "Mermaid render has no SVG data"))
    (with-temp-file cache-file
      (insert svg))
    (plist-put render :cache-file cache-file)))

(defun emacs-hypervisor-markdown-mermaid--cleanup-cache ()
  "Remove Hypervisor Mermaid cache files on Emacs exit."
  (let ((directory
         (expand-file-name "emacs-hypervisor/mermaid/" temporary-file-directory)))
    (when (file-directory-p directory)
      (delete-directory directory t))))

(add-hook 'kill-emacs-hook #'emacs-hypervisor-markdown-mermaid--cleanup-cache)

(defun emacs-hypervisor-markdown-mermaid--viewer-buffer-name (render)
  "Return the preferred viewer buffer name for RENDER."
  (let* ((source-name (or (plist-get render :source-buffer-name) "buffer"))
         (line (with-current-buffer (plist-get render :source-buffer)
                 (line-number-at-pos (plist-get render :block-start)))))
    (format "*Hypervisor Mermaid: %s:%d*" source-name line)))

(defun emacs-hypervisor-markdown-mermaid--display-viewer-buffer (buffer)
  "Display Mermaid viewer BUFFER according to user policy."
  (pcase emacs-hypervisor-markdown-mermaid-viewer-display-action
    ('side-window
     (select-window
      (display-buffer-in-side-window
       buffer
       '((side . right) (window-width . 0.5)))))
    ('frame
     (select-frame-set-input-focus
      (window-frame (display-buffer-pop-up-frame buffer nil))))
    (_
     (pop-to-buffer buffer))))

(defun emacs-hypervisor-markdown-mermaid--viewer-buffer (render)
  "Create and return an image-mode viewer buffer for RENDER."
  (let* ((render (emacs-hypervisor-markdown-mermaid--write-cache-file render))
         (cache-file (plist-get render :cache-file))
         (buffer-name (emacs-hypervisor-markdown-mermaid--viewer-buffer-name
                       render))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents cache-file)
        (set-visited-file-name cache-file t t)
        (emacs-hypervisor-markdown-mermaid-viewer-mode)
        (emacs-hypervisor-markdown-mermaid--prepare-viewer-buffer)
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-render render)
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-source-buffer
                    (plist-get render :source-buffer))
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-cache-file
                    cache-file)))
    buffer))

(defun emacs-hypervisor-markdown-mermaid--viewer-image-position ()
  "Return a buffer position with a displayed image in the current viewer."
  (or (cl-loop for position from (point-min) below (point-max)
               when (eq (car-safe (get-char-property position 'display))
                        'image)
               return position)
      (user-error "No Mermaid image is available in this viewer")))

(defun emacs-hypervisor-markdown-mermaid--goto-viewer-image ()
  "Move point to the displayed image in the current Mermaid viewer."
  (let ((position
         (emacs-hypervisor-markdown-mermaid--viewer-image-position)))
    (goto-char position)
    position))

(defun emacs-hypervisor-markdown-mermaid-viewer-zoom-in (&optional n)
  "Increase the current Mermaid viewer image size."
  (interactive "P")
  (image-increase-size
   n
   (emacs-hypervisor-markdown-mermaid--goto-viewer-image)))

(defun emacs-hypervisor-markdown-mermaid-viewer-zoom-out (&optional n)
  "Decrease the current Mermaid viewer image size."
  (interactive "P")
  (image-decrease-size
   n
   (emacs-hypervisor-markdown-mermaid--goto-viewer-image)))

(defun emacs-hypervisor-markdown-mermaid-viewer-original-size ()
  "Display the current Mermaid viewer image at original size."
  (interactive)
  (emacs-hypervisor-markdown-mermaid--goto-viewer-image)
  (image-transform-original))

(defun emacs-hypervisor-markdown-mermaid-viewer-fit-width ()
  "Fit the current Mermaid viewer image to the window width."
  (interactive)
  (emacs-hypervisor-markdown-mermaid--goto-viewer-image)
  (image-transform-fit-to-width))

(defun emacs-hypervisor-markdown-mermaid-viewer-fit-window ()
  "Fit the current Mermaid viewer image to the whole window."
  (interactive)
  (emacs-hypervisor-markdown-mermaid--goto-viewer-image)
  (image-transform-fit-to-window))

(defun emacs-hypervisor-markdown-mermaid--prepare-viewer-buffer ()
  "Prepare the current image viewer buffer for ephemeral Mermaid display."
  (setq-local buffer-read-only t)
  (setq-local buffer-offer-save nil)
  (set-buffer-modified-p nil)
  (setq-local header-line-format
              emacs-hypervisor-markdown-mermaid--viewer-help))

(defun emacs-hypervisor-markdown-mermaid--overlay-at (position)
  "Return Mermaid preview overlay at POSITION, or nil."
  (cl-find-if
   (lambda (overlay)
     (overlay-get overlay 'emacs-hypervisor-markdown-mermaid-render))
   (overlays-at position)))

(defun emacs-hypervisor-markdown-mermaid-open-viewer (&optional position)
  "Open the Mermaid diagram viewer for the preview near POSITION."
  (interactive "d")
  (let* ((overlay
          (or (emacs-hypervisor-markdown-mermaid--overlay-at
               (or position (point)))
              (cl-find-if
               (lambda (candidate)
                 (overlay-get candidate
                              'emacs-hypervisor-markdown-mermaid-render))
               emacs-hypervisor-markdown-mermaid--overlays)))
         (render (and overlay
                      (overlay-get overlay
                                   'emacs-hypervisor-markdown-mermaid-render))))
    (unless render
      (user-error "No Mermaid preview at point"))
    (let ((buffer (emacs-hypervisor-markdown-mermaid--viewer-buffer render)))
      (emacs-hypervisor-markdown-mermaid--display-viewer-buffer buffer)
      (when emacs-hypervisor-markdown-mermaid-viewer-fit-on-open
        (ignore-errors
          (image-transform-fit-to-width))))))

(defun emacs-hypervisor-markdown-mermaid-open-viewer-at-point (&optional event)
  "Open the Mermaid diagram viewer at point or mouse EVENT."
  (interactive (list last-nonmenu-event))
  (let ((position
         (if (and event (consp event))
             (posn-point (event-end event))
           (point))))
    (emacs-hypervisor-markdown-mermaid-open-viewer position)))

(defun emacs-hypervisor-markdown-mermaid--render-source (source)
  "Render Mermaid SOURCE as SVG and return the extension response."
  (emacs-hypervisor-extension-call
   :mermaid
   :render
   (list :source source
         :style :svg
         :viewport (list :width
                         (emacs-hypervisor-markdown-mermaid--visible-width)))
   10))

(defun emacs-hypervisor-markdown-mermaid-refresh-viewer ()
  "Refresh the current Mermaid viewer from its source buffer."
  (interactive)
  (let* ((source-buffer emacs-hypervisor-markdown-mermaid-viewer-source-buffer)
         (render emacs-hypervisor-markdown-mermaid-viewer-render)
         (cache-file emacs-hypervisor-markdown-mermaid-viewer-cache-file))
    (cond
     ((and (buffer-live-p source-buffer) render)
      (let* ((source (with-current-buffer source-buffer
                       (buffer-substring-no-properties
                        (plist-get render :source-start)
                        (plist-get render :source-end))))
             (response (emacs-hypervisor-markdown-mermaid--render-source
                        source)))
        (if (emacs-hypervisor-markdown-mermaid--response-ok-p response)
            (let ((updated (plist-put render :svg (plist-get response :svg))))
              (setq-local emacs-hypervisor-markdown-mermaid-viewer-render
                          (emacs-hypervisor-markdown-mermaid--write-cache-file
                           updated))
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert-file-contents
                 emacs-hypervisor-markdown-mermaid-viewer-cache-file)
                (emacs-hypervisor-markdown-mermaid-viewer-mode)
                (emacs-hypervisor-markdown-mermaid--prepare-viewer-buffer)
                (setq-local emacs-hypervisor-markdown-mermaid-viewer-render
                            updated)
                (setq-local emacs-hypervisor-markdown-mermaid-viewer-source-buffer
                            source-buffer)
                (setq-local emacs-hypervisor-markdown-mermaid-viewer-cache-file
                            cache-file))
              (message "Refreshed Mermaid viewer"))
          (message "Mermaid refresh failed: %s"
                   (or (plist-get response :message) "render failed")))))
     ((and cache-file (file-readable-p cache-file))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents cache-file)
        (emacs-hypervisor-markdown-mermaid-viewer-mode)
        (emacs-hypervisor-markdown-mermaid--prepare-viewer-buffer)
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-render render)
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-source-buffer
                    source-buffer)
        (setq-local emacs-hypervisor-markdown-mermaid-viewer-cache-file
                    cache-file))
      (message "Source buffer is gone; showing cached Mermaid SVG"))
     (t
      (message "Source buffer is gone and cached Mermaid SVG is unavailable")))))

(defun emacs-hypervisor-markdown-mermaid-close-viewer ()
  "Close the current Mermaid viewer window."
  (interactive)
  (set-buffer-modified-p nil)
  (quit-window t))

(defun emacs-hypervisor-markdown-mermaid-jump-to-source ()
  "Jump from a Mermaid viewer to its original source block."
  (interactive)
  (let ((source-buffer emacs-hypervisor-markdown-mermaid-viewer-source-buffer)
        (render emacs-hypervisor-markdown-mermaid-viewer-render))
    (if (and (buffer-live-p source-buffer) render)
        (progn
          (pop-to-buffer source-buffer)
          (goto-char (plist-get render :block-start)))
      (message "Mermaid source buffer is no longer live"))))

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

(defun emacs-hypervisor-markdown-mermaid--insert-overlay (pos display &optional render)
  "Insert a Mermaid render overlay at POS with DISPLAY.
When RENDER is non-nil, attach it as preview metadata."
  (let ((overlay (make-overlay pos pos nil t nil)))
    (overlay-put overlay 'emacs-hypervisor-markdown-mermaid t)
    (overlay-put overlay 'after-string display)
    (when render
      (overlay-put overlay 'emacs-hypervisor-markdown-mermaid-render render)
      (overlay-put overlay
                   'help-echo
                   "RET or mouse-1: open diagram viewer; C-c C-r: refresh")
      (overlay-put overlay
                   'keymap
                   emacs-hypervisor-markdown-mermaid-preview-map))
    (push overlay emacs-hypervisor-markdown-mermaid--overlays)
    overlay))

(defun emacs-hypervisor-markdown-mermaid--display-for-response (response block)
  "Return an overlay display string or image from RESPONSE."
  (pcase (plist-get response :kind)
    (:image
     (let ((mime (plist-get response :mime))
           (svg (plist-get response :svg)))
       (if (and (equal mime "image/svg+xml")
                (stringp svg)
                (image-type-available-p 'svg))
           (let* ((render (emacs-hypervisor-markdown-mermaid--render-object
                           response
                           block))
                  (image (plist-get render :preview-image)))
             (list
              :display
              (concat "\n"
                      (propertize " "
                                  'display image
                                  'keymap emacs-hypervisor-markdown-mermaid-preview-map
                                  'help-echo
                                  "RET or mouse-1: open diagram viewer; C-c C-r: refresh")
                      "\n")
              :render render))
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
        (let ((display
               (emacs-hypervisor-markdown-mermaid--display-for-response
                response
                block)))
          (if (and (listp display) (plist-member display :display))
              (emacs-hypervisor-markdown-mermaid--insert-overlay
               block-end
               (plist-get display :display)
               (plist-get display :render))
            (emacs-hypervisor-markdown-mermaid--insert-overlay
             block-end
             display)))
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
