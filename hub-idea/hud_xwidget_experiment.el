(require 'cl-lib)
(require 'xwidget)

(defgroup emacs-hypervisor-hud-xwidget nil
  "Customization group for the HUD xwidget-webkit child-frame experiment."
  :group 'hypervisor)

(defcustom emacs-hypervisor-hud-xwidget-width 420
  "Width of the HUD xwidget child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-xwidget)

(defcustom emacs-hypervisor-hud-xwidget-height 560
  "Height of the HUD xwidget child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-xwidget)

(defcustom emacs-hypervisor-hud-xwidget-margin-right 20
  "Margin of the HUD from the right edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-xwidget)

(defcustom emacs-hypervisor-hud-xwidget-margin-top 60
  "Margin of the HUD from the top edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-xwidget)

(defcustom emacs-hypervisor-hud-xwidget-url "https://google.com"
  "The default URL to load in the HUD child frame using xwidget-webkit."
  :type 'string
  :group 'emacs-hypervisor-hud-xwidget)

;;; State Variables

(defvar emacs-hypervisor-hud-xwidget--frame nil
  "The child frame instance of the xwidget HUD.")

(defvar emacs-hypervisor-hud-xwidget--parent-frame nil
  "The parent frame to which the xwidget HUD is anchored.")

(defvar emacs-hypervisor-hud-xwidget--session nil
  "The xwidget-webkit session object.")

;;; Frame Management and Geometry Anchor

(defun emacs-hypervisor-hud-xwidget--reposition-frame ()
  "Lock the child frame strictly to the top-right corner of the parent frame."
  (when (and (frame-live-p emacs-hypervisor-hud-xwidget--frame)
             (frame-live-p emacs-hypervisor-hud-xwidget--parent-frame))
    (let* ((parent-w (frame-pixel-width emacs-hypervisor-hud-xwidget--parent-frame))
           (hud-w emacs-hypervisor-hud-xwidget-width)
           (target-x (- parent-w hud-w emacs-hypervisor-hud-xwidget-margin-right))
           (target-y emacs-hypervisor-hud-xwidget-margin-top))
      (set-frame-position emacs-hypervisor-hud-xwidget--frame target-x target-y)
      (set-frame-size emacs-hypervisor-hud-xwidget--frame 
                      emacs-hypervisor-hud-xwidget-width 
                      emacs-hypervisor-hud-xwidget-height 
                      t))))

(defun emacs-hypervisor-hud-xwidget--make-frame (parent)
  "Create and build the undecorated child frame."
  (let* ((bg (face-background 'default))
         (fg (face-foreground 'default))
         (frame-params
          `((parent-frame . ,parent)
            (no-accept-focus . t)
            (no-focus-on-map . t)
            (minibuffer . nil)
            (undecorated . t)
            (visibility . nil)
            (left . 0)
            (top . 0)
            (width . ,(/ emacs-hypervisor-hud-xwidget-width (frame-char-width)))
            (height . ,(/ emacs-hypervisor-hud-xwidget-height (frame-char-height)))
            (internal-border-width . 0)
            (vertical-scroll-bars . nil)
            (horizontal-scroll-bars . nil)
            (left-fringe . 0)
            (right-fringe . 0)
            (tool-bar-lines . 0)
            (menu-bar-lines . 0)
            (tab-bar-lines . 0)
            (background-color . ,bg)
            (foreground-color . ,fg)
            (cursor-type . nil)
            (unsplittable . t)
            (user-size . t)
            (user-position . t))))
    
    (setq emacs-hypervisor-hud-xwidget--parent-frame parent)
    (setq emacs-hypervisor-hud-xwidget--frame (make-frame frame-params))
    
    (emacs-hypervisor-hud-xwidget--reposition-frame)
    emacs-hypervisor-hud-xwidget--frame))

;;; xwidget-webkit Launcher

(defun emacs-hypervisor-hud-xwidget--initialize-session ()
  "Create the child frame, check for xwidget support, and load the xwidget webview."
  (let ((parent (selected-frame)))
    
    ;; 1. Check if the Emacs binary was compiled with xwidget support
    (unless (featurep 'xwidget-internal)
      (error "HUD Error: This Emacs binary is not compiled with xwidgets (--with-xwidgets). Please use emacs-plus!"))
    
    ;; 2. Clean up any dead frame first
    (unless (frame-live-p emacs-hypervisor-hud-xwidget--frame)
      (emacs-hypervisor-hud-xwidget--make-frame parent)
      (emacs-hypervisor-hud-xwidget--setup-hooks))
    
    ;; Set visibility early so window-buffer operations succeed
    (make-frame-visible emacs-hypervisor-hud-xwidget--frame)
    (raise-frame   emacs-hypervisor-hud-xwidget--frame)
    
    (with-selected-frame emacs-hypervisor-hud-xwidget--frame
      (let* ((window (frame-root-window emacs-hypervisor-hud-xwidget--frame))
             (orig-buffer (window-buffer window)))
        
        (with-selected-window window
          (condition-case err
              (let* ((parent-win-config (with-selected-frame emacs-hypervisor-hud-xwidget--parent-frame (current-window-configuration)))
                     (child-win-config (current-window-configuration))
                     ;; Spawns the session normally, which returns nil in some Emacs versions
                     (_ (xwidget-webkit-new-session emacs-hypervisor-hud-xwidget-url))
                     ;; Retrieve the newly created session from the global state
                     (session (xwidget-webkit-current-session))
                     (buf (xwidget-buffer session)))
                
                ;; Instantly restore window layouts to undo any automatic splits or window changes
                (with-selected-frame emacs-hypervisor-hud-xwidget--parent-frame
                  (set-window-configuration parent-win-config))
                (set-window-configuration child-win-config)
                
                ;; Bind the xwidget buffer strictly to our child frame
                (setq emacs-hypervisor-hud-xwidget--session session)
                
                ;; Clean up mode line, header line, fringes, and line numbers in the xwidget buffer
                (with-current-buffer buf
                  (setq-local mode-line-format nil)
                  (setq-local header-line-format nil)
                  (setq-local display-line-numbers nil)
                  (setq-local left-fringe-width 0)
                  (setq-local right-fringe-width 0))
                
                (set-window-buffer window buf)
                (set-window-dedicated-p window t)
              
              ;; Clean up original blank buffer
              (when (and orig-buffer 
                         (not (eq orig-buffer buf))
                         (buffer-live-p orig-buffer))
                (kill-buffer orig-buffer))
              (message "HUD: Spawning native xwidget-webkit session for: %s" emacs-hypervisor-hud-xwidget-url))
          
          (error
           (message "HUD Error rendering xwidget: %S" err)
           (emacs-hypervisor-hud-xwidget-cleanup))))))
    
    (emacs-hypervisor-hud-xwidget--reposition-frame)))

;;; Resize & Focus Hooks

(defun emacs-hypervisor-hud-xwidget--on-parent-resize (&rest _)
  "Align HUD frame when parent layout changes."
  (when (and (frame-live-p emacs-hypervisor-hud-xwidget--frame)
             (frame-visible-p emacs-hypervisor-hud-xwidget--frame))
    (emacs-hypervisor-hud-xwidget--reposition-frame)))

(defun emacs-hypervisor-hud-xwidget--on-parent-focus-in ()
  "Ensure the HUD stays on top visual layer when parent gains focus."
  (when (and (frame-live-p emacs-hypervisor-hud-xwidget--frame)
             (frame-visible-p emacs-hypervisor-hud-xwidget--frame))
    (raise-frame emacs-hypervisor-hud-xwidget--frame)
    (emacs-hypervisor-hud-xwidget--reposition-frame)))

(defun emacs-hypervisor-hud-xwidget--setup-hooks ()
  "Register window events."
  (add-hook 'window-size-change-functions #'emacs-hypervisor-hud-xwidget--on-parent-resize)
  (add-hook 'focus-in-hook #'emacs-hypervisor-hud-xwidget--on-parent-focus-in)
  (add-hook 'kill-emacs-hook #'emacs-hypervisor-hud-xwidget-cleanup))

(defun emacs-hypervisor-hud-xwidget--remove-hooks ()
  "Tear down registered window hooks."
  (remove-hook 'window-size-change-functions #'emacs-hypervisor-hud-xwidget--on-parent-resize)
  (remove-hook 'focus-in-hook #'emacs-hypervisor-hud-xwidget--on-parent-focus-in)
  (remove-hook 'kill-emacs-hook #'emacs-hypervisor-hud-xwidget-cleanup))

;;; Public Interaction Commands

;;;###autoload
(defun emacs-hypervisor-hud-xwidget-show ()
  "Show the xwidget-webkit floating HUD in the corner, spawning a new session if needed."
  (interactive)
  (if (frame-live-p emacs-hypervisor-hud-xwidget--frame)
      (progn
        (make-frame-visible emacs-hypervisor-hud-xwidget--frame)
        (raise-frame emacs-hypervisor-hud-xwidget--frame)
        (emacs-hypervisor-hud-xwidget--reposition-frame)
        (message "Floating xwidget HUD displayed."))
    (emacs-hypervisor-hud-xwidget--initialize-session)))

;;;###autoload
(defun emacs-hypervisor-hud-xwidget-hide ()
  "Hide the active xwidget HUD."
  (interactive)
  (when (frame-live-p emacs-hypervisor-hud-xwidget--frame)
    (make-frame-invisible emacs-hypervisor-hud-xwidget--frame)
    (message "Floating xwidget HUD hidden.")))

;;;###autoload
(defun emacs-hypervisor-hud-xwidget-toggle ()
  "Toggle the visibility of the xwidget HUD."
  (interactive)
  (if (and (frame-live-p emacs-hypervisor-hud-xwidget--frame)
           (frame-visible-p emacs-hypervisor-hud-xwidget--frame))
      (emacs-hypervisor-hud-xwidget-hide)
    (emacs-hypervisor-hud-xwidget-show)))

;;;###autoload
(defun emacs-hypervisor-hud-xwidget-cleanup ()
  "Tear down all xwidget frames, buffers, and hooks cleanly."
  (interactive)
  (emacs-hypervisor-hud-xwidget--remove-hooks)
  (when (frame-live-p emacs-hypervisor-hud-xwidget--frame)
    (delete-frame emacs-hypervisor-hud-xwidget--frame)
    (setq emacs-hypervisor-hud-xwidget--frame nil))
  (when emacs-hypervisor-hud-xwidget--session
    (let ((buf (xwidget-buffer emacs-hypervisor-hud-xwidget--session)))
      (when (buffer-live-p buf)
        ;; Temporarily remove the xwidget kill query function to bypass the confirmation prompt
        (let ((kill-buffer-query-functions (delq 'xwidget-kill-buffer-query-function kill-buffer-query-functions)))
          (kill-buffer buf))))
    (setq emacs-hypervisor-hud-xwidget--session nil))
  (message "Floating xwidget HUD cleaned up."))

(provide 'hud_xwidget_experiment)
;;; hud_xwidget_experiment.el ends here
