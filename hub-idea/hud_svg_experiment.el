;;; hud_svg_experiment.el --- Persistent SVG child-frame experiment for Emacs Hypervisor HUD -*- lexical-binding: t; -*-

(require 'cl-lib)

(defgroup emacs-hypervisor-hud-svg nil
  "Customization group for the HUD SVG child-frame experiment."
  :group 'hypervisor)

(defcustom emacs-hypervisor-hud-svg-width 380
  "Width of the HUD child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-svg)

(defcustom emacs-hypervisor-hud-svg-height 520
  "Height of the HUD child frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-svg)

(defcustom emacs-hypervisor-hud-svg-margin-right 20
  "Margin of the HUD from the right edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-svg)

(defcustom emacs-hypervisor-hud-svg-margin-top 60
  "Margin of the HUD from the top edge of the parent frame in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud-svg)

(defcustom emacs-hypervisor-hud-svg-opacity 0
  "Opacity of the underlying child frame background. 
Set to 0 (fully transparent) so only the rounded SVG card is visible."
  :type 'integer
  :group 'emacs-hypervisor-hud-svg)

(defcustom emacs-hypervisor-hud-svg-force-text-fallback nil
  "Force the HUD to use the polished text-based fallback layout instead of SVG."
  :type 'boolean
  :group 'emacs-hypervisor-hud-svg)

;;; State Variables

(defvar emacs-hypervisor-hud-svg--frame nil
  "The child frame instance of the SVG HUD.")

(defvar emacs-hypervisor-hud-svg--buffer nil
  "The buffer displaying the SVG HUD.")

(defvar emacs-hypervisor-hud-svg--parent-frame nil
  "The parent frame to which the SVG HUD is anchored.")

;;; SVG Template and Generator

(defun emacs-hypervisor-hud-svg--detect-theme-mode ()
  "Detect whether Emacs is currently using a light or dark theme.
Returns 'light or 'dark."
  (let* ((bg (face-background 'default))
         (rgb (and bg (color-name-to-rgb bg))))
    (if rgb
        (let ((brightness (+ (* (nth 0 rgb) 0.299)
                             (* (nth 1 rgb) 0.587)
                             (* (nth 2 rgb) 0.114))))
          (if (> brightness 0.5) 'light 'dark))
      'light)))

(defun emacs-hypervisor-hud-svg--generate-xml ()
  "Generate raw XML string of the beautiful HUD SVG card using absolute inline styles.
This is 100% compatible with Apple's native CoreGraphics/NSImage SVG engine."
  (let* ((theme (emacs-hypervisor-hud-svg--detect-theme-mode))
         ;; Theme Palette definitions
         (card-bg (if (eq theme 'light) "#FFFFFF" "#1E1E1E"))
         (card-stroke (if (eq theme 'light) "#C6C2B5" "#444446"))
         (text-primary (if (eq theme 'light) "#1C1C1E" "#E5E5EA"))
         (text-secondary (if (eq theme 'light) "#555558" "#AEAEB2"))
         (text-muted (if (eq theme 'light) "#8E8E93" "#636366"))
         (divider-color (if (eq theme 'light) "#E6E2D3" "#2C2C2E"))
         
         ;; Font definitions
         (font-sans "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif")
         (font-mono "'SF Mono', Monaco, Menlo, Consolas, monospace")
         
         ;; Accents
         (green-bg "#E8F5E9")
         (green-fg "#2E7D32")
         (red-bg "#FFEBEE")
         (red-fg "#C62828")
         (blue-bg "#E3F2FD")
         (blue-fg "#1565C0")
         
         ;; SVG Dimensioning
         (width emacs-hypervisor-hud-svg-width)
         (height emacs-hypervisor-hud-svg-height)
         (card-w (- width 40))
         (card-h (- height 40)))
    
    (concat
     "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
     (format "<svg width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" xmlns=\"http://www.w3.org/2000/svg\">\n" width height width height)
     
     "  <!-- Rounded Card Base with simple stroke (No filter for Apple native engine) -->\n"
     (format "  <rect x=\"20\" y=\"20\" width=\"%d\" height=\"%d\" rx=\"22\" ry=\"22\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\" />\n\n"
             card-w card-h card-bg card-stroke)
     
     "  <!-- Header SECTION -->\n"
     (format "  <text x=\"44\" y=\"58\" font-family=\"%s\" font-size=\"18\" font-weight=\"700\" fill=\"%s\">Environment</text>\n" font-sans text-primary)
     
     "  <!-- Changes Chip -->\n"
     (format "  <rect x=\"44\" y=\"78\" width=\"86\" height=\"22\" rx=\"6\" ry=\"6\" fill=\"%s\" />\n" green-bg)
     (format "  <text x=\"54\" y=\"93\" font-family=\"%s\" font-size=\"11\" font-weight=\"bold\" letter-spacing=\"0.5\" fill=\"%s\">⊞ Changes</text>\n" font-sans green-fg)
     (format "  <text x=\"260\" y=\"94\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">+161</text>\n" font-mono green-fg)
     (format "  <text x=\"300\" y=\"94\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">-1</text>\n" font-mono red-fg)
     
     "  <!-- Local Environment -->\n"
     (format "  <path d=\"M46 120 h16 v9 h-16 z M44 130 h20 v1 h-20 z\" fill=\"%s\" />\n" text-secondary)
     (format "  <text x=\"74\" y=\"129\" font-family=\"%s\" font-size=\"13\" font-weight=\"500\" fill=\"%s\">Local Session</text>\n" font-sans text-primary)
     (format "  <text x=\"270\" y=\"128\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">active</text>\n" font-mono green-fg)
     
     "  <!-- Git Branch Indicator -->\n"
     (format "  <path d=\"M48 150 c0-4 4-8 8-8 c0 4-4 8-8 8 M56 142 c2 2 4 6 0 10 M52 146 l-4 6\" stroke=\"%s\" stroke-width=\"1.5\" fill=\"none\" />\n" green-fg)
     (format "  <circle cx=\"48\" cy=\"152\" r=\"2\" fill=\"%s\" />\n" green-fg)
     (format "  <text x=\"74\" y=\"157\" font-family=\"%s\" font-size=\"13\" font-weight=\"500\" fill=\"%s\">Branch</text>\n" font-sans text-secondary)
     (format "  <text x=\"260\" y=\"157\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">main</text>\n" font-mono text-primary)
     
     "  <!-- Commit Status -->\n"
     (format "  <circle cx=\"52\" cy=\"181\" r=\"5\" stroke=\"%s\" stroke-width=\"1.5\" fill=\"none\" />\n" text-muted)
     (format "  <text x=\"74\" y=\"185\" font-family=\"%s\" font-size=\"13\" font-weight=\"500\" fill=\"%s\">Commit Status</text>\n" font-sans text-secondary)
     (format "  <text x=\"220\" y=\"185\" font-family=\"%s\" font-size=\"12\" font-style=\"italic\" fill=\"%s\">clean remote</text>\n" font-sans text-muted)
     
     "  <!-- GitHub Integration -->\n"
     (format "  <circle cx=\"52\" cy=\"209\" r=\"5\" fill=\"%s\" opacity=\"0.5\" />\n" text-muted)
     (format "  <text x=\"74\" y=\"213\" font-family=\"%s\" font-size=\"12\" font-style=\"italic\" fill=\"%s\">GitHub CLI unavailable</text>\n" font-sans text-muted)
     
     ;; Horizontal Separator
     (format "  <line x1=\"44\" y1=\"238\" x2=\"%d\" y2=\"238\" stroke=\"%s\" stroke-width=\"1\" />\n" (- width 44) divider-color)
     
     "  <!-- Sources SECTION -->\n"
     (format "  <text x=\"44\" y=\"272\" font-family=\"%s\" font-size=\"18\" font-weight=\"700\" fill=\"%s\">Sources</text>\n" font-sans text-primary)
     
     "  <!-- Elle MCP Status Card -->\n"
     (format "  <rect x=\"44\" y=\"292\" width=\"24\" height=\"24\" rx=\"6\" ry=\"6\" fill=\"%s\" />\n" blue-bg)
     (format "  <text x=\"51\" y=\"308\" font-size=\"12\" fill=\"%s\">⚙</text>\n" blue-fg)
     (format "  <text x=\"80\" y=\"308\" font-family=\"%s\" font-size=\"13\" font-weight=\"500\" fill=\"%s\">Elle MCP Daemon</text>\n" font-sans text-primary)
     (format "  <text x=\"254\" y=\"308\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">online</text>\n" font-mono green-fg)
     
     ;; Spatial DAG Nodes visual
     (format "  <text x=\"44\" y=\"348\" font-family=\"%s\" font-size=\"15\" font-weight=\"600\" fill=\"%s\">Unit Pipeline DAG</text>\n" font-sans text-secondary)
     
     ;; Connecting Lines
     (format "  <line x1=\"98\" y1=\"390\" x2=\"158\" y2=\"390\" stroke=\"%s\" stroke-width=\"2\" stroke-dasharray=\"3,3\" />\n" text-muted)
     (format "  <line x1=\"182\" y1=\"390\" x2=\"242\" y2=\"390\" stroke=\"%s\" stroke-width=\"2\" />\n" text-muted)
     
     ;; Node 1: Preflight
     (format "  <circle cx=\"88\" cy=\"390\" r=\"16\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\" />\n" green-bg green-fg)
     (format "  <text x=\"88\" y=\"393\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"bold\" fill=\"%s\">PF</text>\n" font-sans green-fg)
     (format "  <text x=\"88\" y=\"420\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"500\" fill=\"%s\">preflight</text>\n" font-sans text-muted)
     
     ;; Node 2: Planning
     (format "  <circle cx=\"170\" cy=\"390\" r=\"16\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\" />\n" green-bg green-fg)
     (format "  <text x=\"170\" y=\"393\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"bold\" fill=\"%s\">PL</text>\n" font-sans green-fg)
     (format "  <text x=\"170\" y=\"420\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"500\" fill=\"%s\">planning</text>\n" font-sans text-muted)
     
     ;; Node 3: Execution
     (format "  <circle cx=\"254\" cy=\"390\" r=\"16\" fill=\"%s\" stroke=\"%s\" stroke-width=\"1.5\" />\n" red-bg red-fg)
     (format "  <text x=\"254\" y=\"393\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"bold\" fill=\"%s\">EX</text>\n" font-sans red-fg)
     (format "  <text x=\"254\" y=\"420\" text-anchor=\"middle\" font-family=\"%s\" font-size=\"10\" font-weight=\"500\" fill=\"%s\">execution</text>\n" font-sans text-muted)
     
     ;; Status strip inside card bottom
     (format "  <rect x=\"44\" y=\"445\" width=\"%d\" height=\"30\" rx=\"8\" ry=\"8\" fill=\"%s\" />\n" 
             (- card-w 48) (if (eq theme 'light) "#F5F5F7" "#2C2C2E"))
     (format "  <text x=\"56\" y=\"464\" font-family=\"%s\" font-size=\"12\" font-weight=\"600\" fill=\"%s\">Units: 12 Running  |  1 Failed (EX)</text>\n" font-mono text-secondary)
     
     "</svg>")))

;;; Buffer Rendering Engine

(defun emacs-hypervisor-hud-svg--get-buffer ()
  "Create or return the hidden HUD SVG buffer."
  (unless (buffer-live-p emacs-hypervisor-hud-svg--buffer)
    (setq emacs-hypervisor-hud-svg--buffer
          (get-buffer-create " *hypervisor-hud-svg*"))
    (with-current-buffer emacs-hypervisor-hud-svg--buffer
      ;; Make it clean, non-interactive
      (setq buffer-read-only t)
      (setq cursor-type nil)
      (setq show-trailing-whitespace nil)
      (setq display-line-numbers nil)
      (setq left-fringe-width 0)
      (setq right-fringe-width 0)
      (setq mode-line-format nil)
      (setq header-line-format nil)
      ;; Force buffer remapping of background to be transparent
      (face-remap-add-relative 'default :background 'unspecified :foreground (face-foreground 'default))))
  emacs-hypervisor-hud-svg--buffer)

(defun emacs-hypervisor-hud-svg--render-text-fallback (buf)
  "Render a highly polished text-based fallback HUD layout in BUF.
This is used if the Emacs binary lacks native SVG capabilities."
  (let* ((theme (emacs-hypervisor-hud-svg--detect-theme-mode))
         (fg-primary (face-foreground 'default))
         (accent-green "#2E7D32")
         (accent-red "#C62828")
         (accent-blue "#1565C0")
         (text-muted "#777777")
         (card-border (if (eq theme 'light) "┌────────────────────────────────────┐" "┌────────────────────────────────────┐"))
         (card-side (if (eq theme 'light) "│" "│"))
         (card-bottom (if (eq theme 'light) "└────────────────────────────────────┘" "└────────────────────────────────────┘")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n")
        ;; Draw top border
        (insert "  " (propertize card-border 'face `(:foreground ,text-muted)) "\n")
        
        ;; Header
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                (propertize "  Environment                      " 'face '(:weight bold :height 1.1))
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; Empty spacer
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                "                                    "
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; Changes Line
        (insert "    " (propertize " ⊞ Changes " 'face `(:background "#E8F5E9" :foreground ,accent-green :weight bold))
                "            "
                (propertize " +161 " 'face `(:foreground ,accent-green :weight bold))
                (propertize " -1 " 'face `(:foreground ,accent-red :weight bold))
                "       " "\n")
        
        ;; Local Session
        (insert "    " (propertize " 💻 Local Session " 'face '(:weight semi-bold))
                "                  "
                (propertize "active" 'face `(:foreground ,accent-green :weight bold)) "\n")
        
        ;; Branch
        (insert "    " (propertize " 🌿 Branch " 'face '(:weight semi-bold))
                "                        "
                (propertize "main" 'face '(:weight bold)) "\n")
        
        ;; Commit
        (insert "    " (propertize " ◌ Commit Status " 'face '(:weight semi-bold))
                "                "
                (propertize "clean" 'face `(:foreground ,text-muted)) "\n")
        
        ;; Spacer & Separator
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                "  ────────────────────────────────  "
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; Sources Header
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                (propertize "  Sources                          " 'face '(:weight bold :height 1.1))
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; MCP Status
        (insert "    " (propertize " ⚙ Elle MCP Daemon " 'face '(:weight semi-bold))
                "                "
                (propertize "online" 'face `(:foreground ,accent-green :weight bold)) "\n")
        
        ;; Spacer & Separator
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                "  ────────────────────────────────  "
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; Pipeline Header
        (insert "  " (propertize card-side 'face `(:foreground ,text-muted))
                (propertize "  Unit Pipeline DAG                " 'face '(:weight bold :height 1.0))
                (propertize card-side 'face `(:foreground ,text-muted)) "\n")
        
        ;; DAG Graphic
        (insert "     [PF:preflight] ── [PL:planning] ── "
                (propertize "[EX:execution]" 'face `(:foreground ,accent-red :weight bold)) "\n")
        
        ;; Status strip
        (insert "     " (propertize " Units: 12 Running  |  1 Failed (EX) " 'face `(:background "#F5F5F7" :foreground ,text-muted)) "\n")
        
        ;; Draw bottom border
        (insert "  " (propertize card-bottom 'face `(:foreground ,text-muted)) "\n")
        (fit-window-to-buffer (get-buffer-window buf t))))))

(defun emacs-hypervisor-hud-svg-update-content ()
  "Compile the SVG XML template and insert it into the buffer as an image object.
Falls back to a premium, theme-adapted text layout if SVG rendering is unavailable or forced."
  (let* ((buf (emacs-hypervisor-hud-svg--get-buffer))
         (svg-supported (and (not emacs-hypervisor-hud-svg-force-text-fallback)
                             (image-type-available-p 'svg))))
    (if (not svg-supported)
        (progn
          (message "HUD: Rendering styled text layout.")
          (when (frame-live-p emacs-hypervisor-hud-svg--frame)
            (set-frame-parameter emacs-hypervisor-hud-svg--frame 'alpha-background 95))
          (emacs-hypervisor-hud-svg--render-text-fallback buf))
      (condition-case err
          (let* ((xml-data (emacs-hypervisor-hud-svg--generate-xml))
                 (img (create-image xml-data 'svg t :ascent 'center)))
            (if (not img)
                (progn
                  (message "HUD: create-image returned nil. Rendering text fallback.")
                  (when (frame-live-p emacs-hypervisor-hud-svg--frame)
                    (set-frame-parameter emacs-hypervisor-hud-svg--frame 'alpha-background 95))
                  (emacs-hypervisor-hud-svg--render-text-fallback buf))
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (when (frame-live-p emacs-hypervisor-hud-svg--frame)
                    (set-frame-parameter emacs-hypervisor-hud-svg--frame 'alpha-background 0))
                  (insert "\n")
                  (insert-image img)
                  (insert "\n")
                  (fit-window-to-buffer (get-buffer-window buf t))))))
        (error
         (message "HUD Error rendering SVG: %S. Rendering text fallback." err)
         (when (frame-live-p emacs-hypervisor-hud-svg--frame)
           (set-frame-parameter emacs-hypervisor-hud-svg--frame 'alpha-background 95))
         (emacs-hypervisor-hud-svg--render-text-fallback buf))))))

;;; Frame Management and Geometry Anchor

(defun emacs-hypervisor-hud-svg--reposition-frame ()
  "Lock the child frame strictly to the top-right corner of the parent frame."
  (when (and (frame-live-p emacs-hypervisor-hud-svg--frame)
             (frame-live-p emacs-hypervisor-hud-svg--parent-frame))
    (let* ((parent-w (frame-pixel-width emacs-hypervisor-hud-svg--parent-frame))
           (hud-w emacs-hypervisor-hud-svg-width)
           (target-x (- parent-w hud-w emacs-hypervisor-hud-svg-margin-right))
           (target-y emacs-hypervisor-hud-svg-margin-top))
      (set-frame-position emacs-hypervisor-hud-svg--frame target-x target-y)
      (set-frame-size emacs-hypervisor-hud-svg--frame 
                      emacs-hypervisor-hud-svg-width 
                      emacs-hypervisor-hud-svg-height 
                      t))))

(defun emacs-hypervisor-hud-svg--make-frame (parent)
  "Create and build the transparent child frame hosting the SVG."
  (let* ((buf (emacs-hypervisor-hud-svg--get-buffer))
         (frame-params
          `((parent-frame . ,parent)
            (no-accept-focus . t)
            (no-focus-on-map . t)
            (minibuffer . nil)
            (undecorated . t)
            (visibility . nil)
            (left . 0)
            (top . 0)
            (width . ,(/ emacs-hypervisor-hud-svg-width (frame-char-width)))
            (height . ,(/ emacs-hypervisor-hud-svg-height (frame-char-height)))
            (internal-border-width . 0) ; SVG handles its own margins/paddings
            (vertical-scroll-bars . nil)
            (horizontal-scroll-bars . nil)
            (left-fringe . 0)
            (right-fringe . 0)
            (tool-bar-lines . 0)
            (menu-bar-lines . 0)
            (tab-bar-lines . 0)
            ;; Set initial background opacity: 95 for text fallback, 0 for transparent SVG
            (alpha-background . ,(if emacs-hypervisor-hud-svg-force-text-fallback 95 emacs-hypervisor-hud-svg-opacity))
            (cursor-type . nil)
            (unsplittable . t)
            (user-size . t)
            (user-position . t))))
    
    (setq emacs-hypervisor-hud-svg--parent-frame parent)
    (setq emacs-hypervisor-hud-svg--frame (make-frame frame-params))
    
    ;; Make window dedicated
    (let ((window (frame-root-window emacs-hypervisor-hud-svg--frame)))
      (set-window-buffer window buf)
      (set-window-dedicated-p window t))
    
    (emacs-hypervisor-hud-svg--reposition-frame)
    emacs-hypervisor-hud-svg--frame))

;;; Resize & Focus Hooks

(defun emacs-hypervisor-hud-svg--on-parent-resize (&rest _)
  "Align HUD frame when parent layout changes."
  (when (and (frame-live-p emacs-hypervisor-hud-svg--frame)
             (frame-visible-p emacs-hypervisor-hud-svg--frame))
    (emacs-hypervisor-hud-svg--reposition-frame)))

(defun emacs-hypervisor-hud-svg--on-parent-focus-in ()
  "Ensure the HUD stays on top visual layer when parent gains focus."
  (when (and (frame-live-p emacs-hypervisor-hud-svg--frame)
             (frame-visible-p emacs-hypervisor-hud-svg--frame))
    (raise-frame emacs-hypervisor-hud-svg--frame)
    (emacs-hypervisor-hud-svg--reposition-frame)))

(defun emacs-hypervisor-hud-svg--setup-hooks ()
  "Register window events."
  (add-hook 'window-size-change-functions #'emacs-hypervisor-hud-svg--on-parent-resize)
  (add-hook 'focus-in-hook #'emacs-hypervisor-hud-svg--on-parent-focus-in)
  (add-hook 'kill-emacs-hook #'emacs-hypervisor-hud-svg-cleanup))

(defun emacs-hypervisor-hud-svg--remove-hooks ()
  "Tear down registered window hooks."
  (remove-hook 'window-size-change-functions #'emacs-hypervisor-hud-svg--on-parent-resize)
  (remove-hook 'focus-in-hook #'emacs-hypervisor-hud-svg--on-parent-focus-in)
  (remove-hook 'kill-emacs-hook #'emacs-hypervisor-hud-svg-cleanup))

;;; Public Interaction Commands

;;;###autoload
(defun emacs-hypervisor-hud-svg-show ()
  "Show the SVG floating HUD in the corner."
  (interactive)
  (let ((parent (selected-frame)))
    (unless (frame-live-p emacs-hypervisor-hud-svg--frame)
      (emacs-hypervisor-hud-svg--make-frame parent)
      (emacs-hypervisor-hud-svg--setup-hooks))
    
    (emacs-hypervisor-hud-svg-update-content)
    (make-frame-visible emacs-hypervisor-hud-svg--frame)
    (raise-frame emacs-hypervisor-hud-svg--frame)
    (emacs-hypervisor-hud-svg--reposition-frame)
    (message "Floating SVG HUD displayed.")))

;;;###autoload
(defun emacs-hypervisor-hud-svg-hide ()
  "Hide the active SVG HUD."
  (interactive)
  (when (frame-live-p emacs-hypervisor-hud-svg--frame)
    (make-frame-invisible emacs-hypervisor-hud-svg--frame)
    (message "Floating SVG HUD hidden.")))

;;;###autoload
(defun emacs-hypervisor-hud-svg-toggle ()
  "Toggle the visibility of the SVG HUD."
  (interactive)
  (if (and (frame-live-p emacs-hypervisor-hud-svg--frame)
           (frame-visible-p emacs-hypervisor-hud-svg--frame))
      (emacs-hypervisor-hud-svg-hide)
    (emacs-hypervisor-hud-svg-show)))

;;;###autoload
(defun emacs-hypervisor-hud-svg-cleanup ()
  "Tear down all SVG frames, buffers, and hooks cleanly."
  (interactive)
  (emacs-hypervisor-hud-svg--remove-hooks)
  (when (frame-live-p emacs-hypervisor-hud-svg--frame)
    (delete-frame emacs-hypervisor-hud-svg--frame)
    (setq emacs-hypervisor-hud-svg--frame nil))
  (when (buffer-live-p emacs-hypervisor-hud-svg--buffer)
    (kill-buffer emacs-hypervisor-hud-svg--buffer)
    (setq emacs-hypervisor-hud-svg--buffer nil))
  (message "Floating SVG HUD cleaned up."))

(provide 'hud_svg_experiment)
;;; hud_svg_experiment.el ends here
