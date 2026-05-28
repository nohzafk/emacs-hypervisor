;;; hud_frame_experiment.el --- Persistent child-frame experiment for Emacs Hypervisor HUD -*- lexical-binding: t; -*-

(require 'cl-lib)

(defgroup emacs-hypervisor-hud-test nil
  "Customization group for the HUD child-frame experiment."
  :group 'hypervisor)

(defcustom emacs-hypervisor-hud-test-width 360
  "Width of the HUD child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-test)

(defcustom emacs-hypervisor-hud-test-height 480
  "Height of the HUD child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-test)

(defcustom emacs-hypervisor-hud-test-margin-right 20
  "Margin of the HUD from the right edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-test)

(defcustom emacs-hypervisor-hud-test-margin-top 60
  "Margin of the HUD from the top edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-test)

(defcustom emacs-hypervisor-hud-test-opacity 95
  "Opacity of the HUD background (0-100)."
  :type 'integer
  :group 'emacs-hypervisor-hud-test)

;;; State Variables

(defvar emacs-hypervisor-hud-test--frame nil
  "The child frame instance of the HUD.")

(defvar emacs-hypervisor-hud-test--buffer nil
  "The buffer displayed inside the HUD child frame.")

(defvar emacs-hypervisor-hud-test--parent-frame nil
  "The parent frame to which the HUD is currently anchored.")

;;; Buffer Rendering Helpers

(defun emacs-hypervisor-hud-test--get-buffer ()
  "Create or return the hidden HUD buffer."
  (unless (buffer-live-p emacs-hypervisor-hud-test--buffer)
    (setq emacs-hypervisor-hud-test--buffer
          (get-buffer-create " *hypervisor-hud-test*"))
    (with-current-buffer emacs-hypervisor-hud-test--buffer
      ;; Make it a clean, non-interactive buffer
      (setq buffer-read-only t)
      (setq cursor-type nil)
      (setq show-trailing-whitespace nil)
      (setq display-line-numbers nil)
      (setq left-fringe-width 0)
      (setq right-fringe-width 0)
      (setq mode-line-format nil)
      (setq header-line-format nil)
      (face-remap-add-relative 'default :background (face-background 'default) :foreground (face-foreground 'default))))
  emacs-hypervisor-hud-test--buffer)

(defun emacs-hypervisor-hud-test-update-content ()
  "Update the content of the HUD buffer with mock data simulating the mockup."
  (let ((buf (emacs-hypervisor-hud-test--get-buffer))
        (bg-color (face-background 'default))
        (fg-color (face-foreground 'default))
        (accent-green "#2E7D32")
        (accent-red "#C62828")
        (border-color "#CCCCCC"))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        
        ;; Header
        (insert (propertize "  Environment" 'face '(:weight bold :height 1.2)))
        (insert "\n\n")
        
        ;; Changes Chip
        (insert "   ")
        (insert (propertize " ⊞ Changes " 'face `(:background "#E8F5E9" :foreground ,accent-green :weight bold)))
        (insert "              ")
        (insert (propertize " +161 " 'face `(:foreground ,accent-green :weight bold)))
        (insert (propertize " -1 " 'face `(:foreground ,accent-red :weight bold)))
        (insert "\n\n")
        
        ;; Local Indicator
        (insert "   ")
        (insert (propertize " 💻 Local " 'face '(:weight semi-bold)))
        (insert "\n\n")
        
        ;; Git Branch
        (insert "   ")
        (insert (propertize " 🌿 main " 'face '(:weight semi-bold)))
        (insert "\n\n")
        
        ;; Commit Status
        (insert "   ")
        (insert (propertize " ◌ Commit " 'face '(:weight semi-bold)))
        (insert "\n\n")
        
        ;; GitHub CLI status
        (insert "   ")
        (insert (propertize " ⊘ GitHub CLI unavailable " 'face '(:foreground "#777777" :slant italic)))
        (insert "\n\n")
        
        ;; Horizontal Separator
        (insert "  " (make-string 36 ?─) "\n\n")
        
        ;; Sources Header
        (insert (propertize "  Sources" 'face '(:weight bold :height 1.1)))
        (insert "\n\n")
        
        ;; Elle MCP Status
        (insert "   ")
        (insert (propertize " ⚙ Elle MCP " 'face '(:weight semi-bold)))
        (insert "\n\n")
        
        ;; DAG/Unit Health (Mock visual)
        (insert "   [ Running: 12  Failed: 0  Reloading: 0 ]\n")
        
        ;; Force redisplay
        (fit-window-to-buffer (get-buffer-window buf t))))))

;;; Frame Construction and Management

(defun emacs-hypervisor-hud-test--reposition-frame ()
  "Recalculate and update the child frame's position to anchor at the top-right."
  (when (and (frame-live-p emacs-hypervisor-hud-test--frame)
             (frame-live-p emacs-hypervisor-hud-test--parent-frame))
    (let* ((parent-width (frame-pixel-width emacs-hypervisor-hud-test--parent-frame))
           (hud-width emacs-hypervisor-hud-test-width)
           ;; Calculate coordinate: right-aligned with margin
           (target-left (- parent-width hud-width emacs-hypervisor-hud-test-margin-right))
           (target-top emacs-hypervisor-hud-test-margin-top))
      ;; Apply position changes smoothly
      (set-frame-position emacs-hypervisor-hud-test--frame target-left target-top)
      ;; Ensure size is locked to preferences
      (set-frame-size emacs-hypervisor-hud-test--frame 
                      emacs-hypervisor-hud-test-width 
                      emacs-hypervisor-hud-test-height 
                      t))))

(defun emacs-hypervisor-hud-test--make-frame (parent)
  "Create and return the child frame configured for the HUD."
  (let* ((buf (emacs-hypervisor-hud-test--get-buffer))
         (bg (face-background 'default))
         (fg (face-foreground 'default))
         (frame-params
          `((parent-frame . ,parent)
            (no-accept-focus . t)
            (no-focus-on-map . t)
            (minibuffer . nil)
            (undecorated . t)
            (visibility . nil)
            (left . 0) ; Will be recalculated by reposition-frame
            (top . 0)
            (width . ,(/ emacs-hypervisor-hud-test-width (frame-char-width)))
            (height . ,(/ emacs-hypervisor-hud-test-height (frame-char-height)))
            (internal-border-width . 16) ; Serves as native padding inside the frame
            (vertical-scroll-bars . nil)
            (horizontal-scroll-bars . nil)
            (left-fringe . 0)
            (right-fringe . 0)
            (tool-bar-lines . 0)
            (menu-bar-lines . 0)
            (tab-bar-lines . 0)
            (menu-bar-lines . 0)
            (background-color . ,bg)
            (foreground-color . ,fg)
            (alpha-background . ,emacs-hypervisor-hud-test-opacity)
            (cursor-type . nil)
            (line-spacing . 4)
            (unsplittable . t)
            (user-size . t)
            (user-position . t))))
    
    (setq emacs-hypervisor-hud-test--parent-frame parent)
    (setq emacs-hypervisor-hud-test--frame (make-frame frame-params))
    
    ;; Set buffer and window parameters
    (let ((window (frame-root-window emacs-hypervisor-hud-test--frame)))
      (set-window-buffer window buf)
      (set-window-dedicated-p window t))
    
    ;; Initial positioning
    (emacs-hypervisor-hud-test--reposition-frame)
    emacs-hypervisor-hud-test--frame))

;;; Hooks and Event Handling

(defun emacs-hypervisor-hud-test--on-parent-resize (&rest _)
  "Hook called when frame geometry or configuration changes."
  (when (and (frame-live-p emacs-hypervisor-hud-test--frame)
             (frame-visible-p emacs-hypervisor-hud-test--frame))
    (emacs-hypervisor-hud-test--reposition-frame)))

(defun emacs-hypervisor-hud-test--on-parent-focus-in ()
  "Hook called when parent frame gains focus. Ensures HUD stays on top."
  (when (and (frame-live-p emacs-hypervisor-hud-test--frame)
             (frame-visible-p emacs-hypervisor-hud-test--frame))
    (raise-frame emacs-hypervisor-hud-test--frame)
    (emacs-hypervisor-hud-test--reposition-frame)))

(defun emacs-hypervisor-hud-test--setup-hooks ()
  "Register window hooks to keep HUD frame dynamically anchored."
  (add-hook 'window-size-change-functions #'emacs-hypervisor-hud-test--on-parent-resize)
  (add-hook 'focus-in-hook #'emacs-hypervisor-hud-test--on-parent-focus-in)
  (add-hook 'kill-emacs-hook #'emacs-hypervisor-hud-test-cleanup))

(defun emacs-hypervisor-hud-test--remove-hooks ()
  "Clean up registered hooks."
  (remove-hook 'window-size-change-functions #'emacs-hypervisor-hud-test--on-parent-resize)
  (remove-hook 'focus-in-hook #'emacs-hypervisor-hud-test--on-parent-focus-in)
  (remove-hook 'kill-emacs-hook #'emacs-hypervisor-hud-test-cleanup))

;;; User Commands

;;;###autoload
(defun emacs-hypervisor-hud-test-show ()
  "Create and display the HUD child frame."
  (interactive)
  (let ((parent (selected-frame)))
    ;; Clean up any existing dead frame
    (unless (frame-live-p emacs-hypervisor-hud-test--frame)
      (emacs-hypervisor-hud-test--make-frame parent)
      (emacs-hypervisor-hud-test--setup-hooks))
    
    (emacs-hypervisor-hud-test-update-content)
    (make-frame-visible emacs-hypervisor-hud-test--frame)
    (raise-frame emacs-hypervisor-hud-test--frame)
    (emacs-hypervisor-hud-test--reposition-frame)
    (message "Hypervisor HUD child frame displayed.")))

;;;###autoload
(defun emacs-hypervisor-hud-test-hide ()
  "Hide the active HUD child frame."
  (interactive)
  (when (frame-live-p emacs-hypervisor-hud-test--frame)
    (make-frame-invisible emacs-hypervisor-hud-test--frame)
    (message "Hypervisor HUD child frame hidden.")))

;;;###autoload
(defun emacs-hypervisor-hud-test-toggle ()
  "Toggle the visibility of the Hypervisor HUD child frame."
  (interactive)
  (if (and (frame-live-p emacs-hypervisor-hud-test--frame)
           (frame-visible-p emacs-hypervisor-hud-test--frame))
      (emacs-hypervisor-hud-test-hide)
    (emacs-hypervisor-hud-test-show)))

(defun emacs-hypervisor-hud-test-cleanup ()
  "Completely tear down and delete the child frame and buffers."
  (interactive)
  (emacs-hypervisor-hud-test--remove-hooks)
  (when (frame-live-p emacs-hypervisor-hud-test--frame)
    (delete-frame emacs-hypervisor-hud-test--frame)
    (setq emacs-hypervisor-hud-test--frame nil))
  (when (buffer-live-p emacs-hypervisor-hud-test--buffer)
    (kill-buffer emacs-hypervisor-hud-test--buffer)
    (setq emacs-hypervisor-hud-test--buffer nil))
  (message "Hypervisor HUD child frame cleaned up."))

(provide 'hud_frame_experiment)
;;; hud_frame_experiment.el ends here
