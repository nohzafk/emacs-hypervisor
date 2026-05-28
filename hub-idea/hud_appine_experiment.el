;;; hud_appine_experiment.el --- Persistent Appine WebKit child-frame experiment for Emacs Hypervisor -*- lexical-binding: t; -*-

(require 'cl-lib)

(defgroup emacs-hypervisor-hud-appine nil
  "Customization group for the HUD Appine WebKit child-frame experiment."
  :group 'hypervisor)

(defcustom emacs-hypervisor-hud-appine-width 420
  "Width of the HUD Appine child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-appine)

(defcustom emacs-hypervisor-hud-appine-height 560
  "Height of the HUD Appine child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-appine)

(defcustom emacs-hypervisor-hud-appine-margin-right 20
  "Margin of the HUD from the right edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-appine)

(defcustom emacs-hypervisor-hud-appine-margin-top 60
  "Margin of the HUD from the top edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-appine)

(defcustom emacs-hypervisor-hud-appine-url "https://google.com"
  "The default URL to load in the HUD child frame using Appine."
  :type 'string
  :group 'emacs-hypervisor-hud-appine)

;;; State Variables

(defvar emacs-hypervisor-hud-appine--frame nil
  "The child frame instance of the Appine HUD.")

(defvar emacs-hypervisor-hud-appine--parent-frame nil
  "The parent frame to which the Appine HUD is anchored.")

(defvar emacs-hypervisor-hud-appine--buffer nil
  "The Appine buffer displayed inside the child frame.")

;;; Frame Management and Geometry Anchor

(defun emacs-hypervisor-hud-appine--reposition-frame ()
  "Lock the child frame strictly to the top-right corner of the parent frame."
  (when (and (frame-live-p emacs-hypervisor-hud-appine--frame)
             (frame-live-p emacs-hypervisor-hud-appine--parent-frame))
    (let* ((parent-w (frame-pixel-width emacs-hypervisor-hud-appine--parent-frame))
           (hud-w emacs-hypervisor-hud-appine-width)
           (target-x (- parent-w hud-w emacs-hypervisor-hud-appine-margin-right))
           (target-y emacs-hypervisor-hud-appine-margin-top))
      (set-frame-position emacs-hypervisor-hud-appine--frame target-x target-y)
      (set-frame-size emacs-hypervisor-hud-appine--frame 
                      emacs-hypervisor-hud-appine-width 
                      emacs-hypervisor-hud-appine-height 
                      t))))

(defun emacs-hypervisor-hud-appine--make-frame (parent)
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
            (width . ,(/ emacs-hypervisor-hud-appine-width (frame-char-width)))
            (height . ,(/ emacs-hypervisor-hud-appine-height (frame-char-height)))
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
    
    (setq emacs-hypervisor-hud-appine--parent-frame parent)
    (setq emacs-hypervisor-hud-appine--frame (make-frame frame-params))
    
    (emacs-hypervisor-hud-appine--reposition-frame)
    emacs-hypervisor-hud-appine--frame))

;;; Appine Loader

(defun emacs-hypervisor-hud-appine--initialize-session ()
  "Create the child frame, select its window, load Appine, and point to the target URL."
  (let ((parent (selected-frame)))
    ;; Clean up any dead frame first
    (unless (frame-live-p emacs-hypervisor-hud-appine--frame)
      (emacs-hypervisor-hud-appine--make-frame parent)
      (emacs-hypervisor-hud-appine--setup-hooks))
    
    ;; Set visibility early so window-buffer operations succeed
    (make-frame-visible emacs-hypervisor-hud-appine--frame)
    (raise-frame   emacs-hypervisor-hud-appine--frame)
    
    (with-selected-frame emacs-hypervisor-hud-appine--frame
      (let* ((window (frame-root-window emacs-hypervisor-hud-appine--frame))
             (orig-buffer (window-buffer window)))
        
        ;; Select the child frame window to force Appine to render inside it
        (select-window window)
        
        (condition-case err
            (progn
              ;; 1. Load the Appine package
              (require 'appine)
              
              ;; 2. Open the URL using Appine (spawns native WKWebView).
              ;; We use cl-letf* to intercept Emacs buffer-display calls (like pop-to-buffer or display-buffer)
              ;; and force them to load strictly inside our child frame window. This prevents Appine from
              ;; spawning a duplicate split window on your parent frame!
              (message "HUD: Spawning native Appine WebKit session for: %s" emacs-hypervisor-hud-appine-url)
              (cl-letf* ((selected-win (selected-window))
                         ((symbol-function 'pop-to-buffer)
                          (lambda (buf &rest _)
                            (set-window-buffer selected-win buf)
                            (set-buffer buf)
                            selected-win))
                         ((symbol-function 'display-buffer)
                          (lambda (buf &rest _)
                            (set-window-buffer selected-win buf)
                            selected-win))
                         ((symbol-function 'switch-to-buffer)
                          (lambda (buf &rest _)
                            (set-window-buffer selected-win buf)
                            (set-buffer buf)
                            selected-win))
                         ((symbol-function 'switch-to-buffer-other-window)
                          (lambda (buf &rest _)
                            (set-window-buffer selected-win buf)
                            (set-buffer buf)
                            selected-win)))
                (appine-open-url emacs-hypervisor-hud-appine-url))
              
              ;; 3. Capture the newly created Appine buffer
              (setq emacs-hypervisor-hud-appine--buffer (current-buffer))
              
              ;; 4. Set window properties
              (set-window-dedicated-p window t)
              
              ;; 5. Clean up the original empty buffer of the frame if it differs
              (when (and orig-buffer 
                         (not (eq orig-buffer emacs-hypervisor-hud-appine--buffer))
                         (buffer-live-p orig-buffer))
                (kill-buffer orig-buffer)))
          
          (error
           (message "HUD Error loading Appine: %S. Is chaoswork/appine installed?" err)
           (emacs-hypervisor-hud-appine-cleanup)))))
    
    (emacs-hypervisor-hud-appine--reposition-frame)))

;;; Resize & Focus Hooks

(defun emacs-hypervisor-hud-appine--on-parent-resize (&rest _)
  "Align HUD frame when parent layout changes."
  (when (and (frame-live-p emacs-hypervisor-hud-appine--frame)
             (frame-visible-p emacs-hypervisor-hud-appine--frame))
    (emacs-hypervisor-hud-appine--reposition-frame)))

(defun emacs-hypervisor-hud-appine--on-parent-focus-in ()
  "Ensure the HUD stays on top visual layer when parent gains focus."
  (when (and (frame-live-p emacs-hypervisor-hud-appine--frame)
             (frame-visible-p emacs-hypervisor-hud-appine--frame))
    (raise-frame emacs-hypervisor-hud-appine--frame)
    (emacs-hypervisor-hud-appine--reposition-frame)))

(defun emacs-hypervisor-hud-appine--setup-hooks ()
  "Register window events."
  (add-hook 'window-size-change-functions #'emacs-hypervisor-hud-appine--on-parent-resize)
  (add-hook 'focus-in-hook #'emacs-hypervisor-hud-appine--on-parent-focus-in)
  (add-hook 'kill-emacs-hook #'emacs-hypervisor-hud-appine-cleanup))

(defun emacs-hypervisor-hud-appine--remove-hooks ()
  "Tear down registered window hooks."
  (remove-hook 'window-size-change-functions #'emacs-hypervisor-hud-appine--on-parent-resize)
  (remove-hook 'focus-in-hook #'emacs-hypervisor-hud-appine--on-parent-focus-in)
  (remove-hook 'kill-emacs-hook #'emacs-hypervisor-hud-appine-cleanup))

;;; Public Interaction Commands

;;;###autoload
(defun emacs-hypervisor-hud-appine-show ()
  "Show the Appine floating HUD in the corner, spawning a new session if needed."
  (interactive)
  (if (frame-live-p emacs-hypervisor-hud-appine--frame)
      (progn
        (make-frame-visible emacs-hypervisor-hud-appine--frame)
        (raise-frame emacs-hypervisor-hud-appine--frame)
        (emacs-hypervisor-hud-appine--reposition-frame)
        (message "Floating Appine HUD displayed."))
    (emacs-hypervisor-hud-appine--initialize-session)))

;;;###autoload
(defun emacs-hypervisor-hud-appine-hide ()
  "Hide the active Appine HUD."
  (interactive)
  (when (frame-live-p emacs-hypervisor-hud-appine--frame)
    (make-frame-invisible emacs-hypervisor-hud-appine--frame)
    (message "Floating Appine HUD hidden.")))

;;;###autoload
(defun emacs-hypervisor-hud-appine-toggle ()
  "Toggle the visibility of the Appine HUD."
  (interactive)
  (if (and (frame-live-p emacs-hypervisor-hud-appine--frame)
           (frame-visible-p emacs-hypervisor-hud-appine--frame))
      (emacs-hypervisor-hud-appine-hide)
    (emacs-hypervisor-hud-appine-show)))

;;;###autoload
(defun emacs-hypervisor-hud-appine-cleanup ()
  "Tear down all Appine frames, buffers, and hooks cleanly."
  (interactive)
  (emacs-hypervisor-hud-appine--remove-hooks)
  (when (frame-live-p emacs-hypervisor-hud-appine--frame)
    (delete-frame emacs-hypervisor-hud-appine--frame)
    (setq emacs-hypervisor-hud-appine--frame nil))
  (when (buffer-live-p emacs-hypervisor-hud-appine--buffer)
    (kill-buffer emacs-hypervisor-hud-appine--buffer)
    (setq emacs-hypervisor-hud-appine--buffer nil))
  (message "Floating Appine HUD cleaned up."))

(provide 'hud_appine_experiment)
;;; hud_appine_experiment.el ends here
