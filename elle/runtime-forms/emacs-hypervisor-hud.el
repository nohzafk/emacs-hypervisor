;;; emacs-hypervisor-hud.el --- Corner HUD rendered in xwidget-webkit -*- lexical-binding: t; -*-
;;
;; Architecture: actor-mediated thin rendering surface.
;;
;; All HUD state is owned by the Elle extension actor (extension-hud.lisp).
;; This module is a rendering surface only:
;;   - Creates/manages the xwidget-webkit child frame
;;   - Receives :hud-state-changed events from the actor → pushes JSON to WASM
;;   - Intercepts click-back URIs → routes them to the actor via :extension-call
;;
;; Data collection flow (event-driven):
;;   [buffer switch / save / toggle] → debounced idle timer (0.5s)
;;     → emacs-hypervisor-extension-call :hud :collect {:repo_path ...}
;;     → Elle actor collects via std/git (libgit2 FFI)
;;     → updates @*hud-state* → emits :hud-state-changed event
;;     → emacs-hypervisor-hud--on-state-changed receives it
;;     → pushes JSON to xwidget via window.hudPushState()
;;
;; Click-back flow:
;;   [user clicks button in egui] → emacs-hud://command/X URI
;;     → xwidget-webkit-pre-navigation-functions intercepts
;;     → emacs-hypervisor-extension-call :hud :action {:command X}
;;     → Elle actor handles the command

(require 'cl-lib)
(require 'xwidget)
(require 'json)
(require 'url-util)

(defgroup emacs-hypervisor-hud nil
  "HUD display settings."
  :group 'hypervisor)

(defcustom emacs-hypervisor-hud-width 280
  "Width of the corner HUD in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud)

(defcustom emacs-hypervisor-hud-height 320
  "Height of the corner HUD in pixels."
  :type 'integer
  :group 'emacs-hypervisor-hud)

(defcustom emacs-hypervisor-hud-margin-right 20
  "Horizontal offset from the right edge of Emacs."
  :type 'integer
  :group 'emacs-hypervisor-hud)

(defcustom emacs-hypervisor-hud-margin-top 60
  "Vertical offset from the top edge of Emacs."
  :type 'integer
  :group 'emacs-hypervisor-hud)

(defcustom emacs-hypervisor-hud-debug t
  "When non-nil, log HUD data collection to *Messages* for debugging.
Logs the resolved repo path, the state payload received from the Elle
actor, and the JSON pushed to the WASM renderer.  This lets you tell a
backend collection issue (payload already wrong) from a frontend display
issue (payload correct, render wrong)."
  :type 'boolean
  :group 'emacs-hypervisor-hud)

;; State Variables
(defvar emacs-hypervisor-hud--frame nil
  "The child frame instance of the corner HUD.")

(defvar emacs-hypervisor-hud--parent-frame nil
  "The parent frame to which the HUD is anchored.")

(defvar emacs-hypervisor-hud--session nil
  "The xwidget-webkit session object.")

(defvar emacs-hypervisor-hud--url nil
  "The file URL of the HUD HTML shell.")

;; Event-driven trigger state
(defvar emacs-hypervisor-hud--debounce-timer nil
  "Idle timer for debouncing collect triggers.")

;; ---------------------------------------------------------------------------
;; Frame management (inherently Elisp-side — no actor involvement needed)
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--reposition-frame ()
  "Lock the child frame strictly to the top-right corner of the parent frame."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-live-p emacs-hypervisor-hud--parent-frame))
    (let* ((parent-w (frame-pixel-width emacs-hypervisor-hud--parent-frame))
           (hud-w emacs-hypervisor-hud-width)
           (target-x (- parent-w hud-w emacs-hypervisor-hud-margin-right))
           (target-y emacs-hypervisor-hud-margin-top))
      (set-frame-position emacs-hypervisor-hud--frame target-x target-y)
      (set-frame-size emacs-hypervisor-hud--frame
                      emacs-hypervisor-hud-width
                      emacs-hypervisor-hud-height
                      t))))

(defun emacs-hypervisor-hud--make-frame (parent)
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
            (width . ,(/ emacs-hypervisor-hud-width (frame-char-width)))
            (height . ,(/ emacs-hypervisor-hud-height (frame-char-height)))
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
            (alpha-background . 0)
            (cursor-type . nil)
            (unsplittable . t)
            (user-size . t)
            (user-position . t))))

    (setq emacs-hypervisor-hud--parent-frame parent)
    (setq emacs-hypervisor-hud--frame (make-frame frame-params))
    ;; A newly created frame displays whatever buffer was current at creation
    ;; time (e.g. the user's config.el).  Session setup later captures and kills
    ;; the child window's buffer to clean up the xwidget placeholder — if that
    ;; buffer is one of the user's real buffers it gets destroyed, which is why
    ;; the active buffer was being buried.  Point the child window at a private
    ;; throwaway buffer so the cleanup only ever targets our own buffer.
    (set-window-buffer (frame-root-window emacs-hypervisor-hud--frame)
                       (get-buffer-create " *emacs-hypervisor-hud-placeholder*"))
    (emacs-hypervisor-hud--reposition-frame)
    emacs-hypervisor-hud--frame))

(defun emacs-hypervisor-hud--on-parent-resize (&rest _)
  "Align HUD frame when parent layout changes."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-visible-p emacs-hypervisor-hud--frame))
    (emacs-hypervisor-hud--reposition-frame)))

(defun emacs-hypervisor-hud--on-parent-focus-in ()
  "Ensure the HUD stays on top visual layer when parent gains focus."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-visible-p emacs-hypervisor-hud--frame))
    (raise-frame emacs-hypervisor-hud--frame)
    (emacs-hypervisor-hud--reposition-frame)))

;; ---------------------------------------------------------------------------
;; Actor-mediated state push (event-driven)
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--fixup-sexp-rpc-plist (plist)
  "Fix sexp-rpc plist values for JSON encoding.
Elle booleans arrive as symbols `false'/`true' instead of :json-false/t.
Elle empty lists arrive as nil instead of empty vectors."
  (let ((result nil)
        (rest plist))
    (while rest
      (let ((key (car rest))
            (val (cadr rest)))
        (setq rest (cddr rest))
        (push key result)
        (push (cond
               ((eq val 'false) :json-false)
               ((eq val 'true) t)
               ((and (null val) (memq key '(:units)))
                (vector))  ; nil for array fields → empty JSON array
               ((listp val)
                ;; Non-nil list: could be array of plists (units)
                (vconcat (mapcar
                          (lambda (item)
                            (if (and (listp item) (keywordp (car-safe item)))
                                (emacs-hypervisor-hud--fixup-sexp-rpc-plist item)
                              item))
                          val)))
               (t val))
              result)))
    (nreverse result)))

(defun emacs-hypervisor-hud--push-state-to-wasm (state-plist)
  "Push STATE-PLIST as JSON to the WASM application via xwidget-webkit.
This is an internal function called by the actor event handler."
  (when (and emacs-hypervisor-hud--session
             (frame-live-p emacs-hypervisor-hud--frame))
    (let* ((json-false :json-false)
           (sanitized (emacs-hypervisor-hud--fixup-sexp-rpc-plist state-plist))
           (json-str (json-encode sanitized))
           (script (format "if (window.hudPushState) { window.hudPushState(%S); }" json-str)))
      (when emacs-hypervisor-hud-debug
        (message "HUD [push json to WASM]: %s" json-str))
      (xwidget-webkit-execute-script emacs-hypervisor-hud--session script))))

(defun emacs-hypervisor-hud--on-state-changed (payload)
  "Handle :hud-state-changed event from the Elle extension actor.
PAYLOAD contains the serialized HUD state.  Push it to the WASM renderer."
  (when emacs-hypervisor-hud-debug
    (message "HUD [recv state from Elle]: %S" payload))
  (emacs-hypervisor-hud--push-state-to-wasm payload))

(defun emacs-hypervisor-hud--url-with-theme ()
  "Return the HUD URL with the current Emacs theme appended as a fragment.
The WASM renderer reads `#bg=...&fg=...' on load and paints its first frame
with the correct colors, avoiding the dark-default-to-theme flash."
  (let ((bg (face-background 'default nil 'default))
        (fg (face-foreground 'default nil 'default)))
    (if (and emacs-hypervisor-hud--url bg fg)
        (format "%s#bg=%s&fg=%s"
                emacs-hypervisor-hud--url
                (url-hexify-string bg)
                (url-hexify-string fg))
      emacs-hypervisor-hud--url)))

(defun emacs-hypervisor-hud--push-theme ()
  "Push Emacs theme colors directly to the WASM renderer.
Theme colors bypass the actor — they are a presentation concern."
  (when (and emacs-hypervisor-hud--session
             (frame-live-p emacs-hypervisor-hud--frame))
    (let* ((bg (face-background 'default nil 'default))
           (fg (face-foreground 'default nil 'default))
           (json-str (json-encode (list :bg bg :fg fg)))
           (script (format "if (window.hudPushTheme) { window.hudPushTheme(%S); }" json-str)))
      (xwidget-webkit-execute-script emacs-hypervisor-hud--session script))))

;; ---------------------------------------------------------------------------
;; Event-driven data collection triggers
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--current-repo-path ()
  "Return the git repo root for the current buffer, or nil.
Uses `vc-root-dir' when available, falling back to .git sentinel."
  (or (and (fboundp 'vc-root-dir) (vc-root-dir))
      (locate-dominating-file default-directory ".git")))

(defun emacs-hypervisor-hud--resolve-repo-path ()
  "Resolve the git repo root from the parent frame's active content buffer.
Collection runs from idle timers, where `current-buffer' is unpredictable
\(often the xwidget HUD buffer or the minibuffer).  We therefore resolve
against the buffer shown in the parent frame's selected window — that is the
buffer the user is actually looking at — so the HUD follows the active
project rather than whatever buffer the timer happened to fire in."
  (let ((buf (if (frame-live-p emacs-hypervisor-hud--parent-frame)
                 (window-buffer
                  (frame-selected-window emacs-hypervisor-hud--parent-frame))
               (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (emacs-hypervisor-hud--current-repo-path)))))

(defun emacs-hypervisor-hud--trigger-collect ()
  "Send a :collect request to the Elle HUD actor with current context.
The actor collects git data natively via libgit2 and emits a state event."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-visible-p emacs-hypervisor-hud--frame))
    (emacs-hypervisor-hud--push-theme)
    (let* ((repo-path (emacs-hypervisor-hud--resolve-repo-path))
           ;; Normalize: expand and strip trailing slash for clean project name
           (repo-path (when repo-path
                        (directory-file-name (expand-file-name repo-path))))
           (mcp-online (and (fboundp 'emacs-hypervisor-live-p)
                            (emacs-hypervisor-live-p)))
           (gh-available (not (null (executable-find "gh"))))
           (args (list :repo_path repo-path
                       :mcp_online (if mcp-online t :json-false)
                       :gh_available (if gh-available t :json-false)
                       :location "Local")))
      (when emacs-hypervisor-hud-debug
        (message "HUD [collect] repo=%s mcp=%s gh=%s" repo-path mcp-online gh-available))
      (condition-case err
          (emacs-hypervisor-extension-call :hud :collect args)
        (error
         (message "HUD: collect trigger failed: %S" err))))))

(defun emacs-hypervisor-hud--retry-initial-collect (attempt)
  "Try the first collect, retrying up to 5 times with 1s backoff.
The extension actor may not be ready during Emacs startup."
  (condition-case err
      (progn
        (emacs-hypervisor-hud--trigger-collect)
        (message "HUD: Initial collect succeeded."))
    (error
     (if (< attempt 5)
         (progn
           (message "HUD: Initial collect attempt %d failed, retrying... (%S)"
                    (1+ attempt) (error-message-string err))
           (run-with-timer 1.0 nil
             (lambda () (emacs-hypervisor-hud--retry-initial-collect (1+ attempt)))))
       (message "HUD: Initial collect failed after %d attempts: %S"
                (1+ attempt) err)))))

(defun emacs-hypervisor-hud--on-buffer-switch (&rest _)
  "Debounced handler for buffer/window change events.
Cancels any pending trigger and schedules a new one after 0.5s idle."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-visible-p emacs-hypervisor-hud--frame))
    (when emacs-hypervisor-hud--debounce-timer
      (cancel-timer emacs-hypervisor-hud--debounce-timer))
    (setq emacs-hypervisor-hud--debounce-timer
          (run-with-idle-timer 0.5 nil #'emacs-hypervisor-hud--trigger-collect))))

(defun emacs-hypervisor-hud--on-save ()
  "Trigger collect immediately after saving a file (no debounce)."
  (when (and (frame-live-p emacs-hypervisor-hud--frame)
             (frame-visible-p emacs-hypervisor-hud--frame))
    ;; Cancel any pending debounced trigger — this save supersedes it
    (when emacs-hypervisor-hud--debounce-timer
      (cancel-timer emacs-hypervisor-hud--debounce-timer)
      (setq emacs-hypervisor-hud--debounce-timer nil))
    (run-with-idle-timer 0.1 nil #'emacs-hypervisor-hud--trigger-collect)))

(defun emacs-hypervisor-hud--setup-trigger-hooks ()
  "Register event-driven hooks that trigger data collection."
  (add-hook 'window-buffer-change-functions #'emacs-hypervisor-hud--on-buffer-switch)
  (add-hook 'window-selection-change-functions #'emacs-hypervisor-hud--on-buffer-switch)
  (add-hook 'after-save-hook #'emacs-hypervisor-hud--on-save))

(defun emacs-hypervisor-hud--remove-trigger-hooks ()
  "Remove event-driven collection hooks."
  (remove-hook 'window-buffer-change-functions #'emacs-hypervisor-hud--on-buffer-switch)
  (remove-hook 'window-selection-change-functions #'emacs-hypervisor-hud--on-buffer-switch)
  (remove-hook 'after-save-hook #'emacs-hypervisor-hud--on-save)
  (when emacs-hypervisor-hud--debounce-timer
    (cancel-timer emacs-hypervisor-hud--debounce-timer)
    (setq emacs-hypervisor-hud--debounce-timer nil)))

;; ---------------------------------------------------------------------------
;; Actor-mediated click-back handling
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--pre-navigation-hook (xwidget url)
  "Intercept HUD click actions and route them through the extension actor."
  (when (and emacs-hypervisor-hud--session
             (eq xwidget emacs-hypervisor-hud--session)
             (string-prefix-p "emacs-hud://" url))
    (let ((cmd (substring url (length "emacs-hud://command/"))))
      ;; Route through the actor — the actor decides what to do
      (condition-case err
          (let ((response (emacs-hypervisor-extension-call :hud :action
                            (list :command cmd))))
            (when (plist-get response :action)
              (pcase (plist-get response :action)
                (:rerun-diagnostics
                 (message "HUD: Actor acknowledged diagnostics re-run.")
                 (when (fboundp 'emacs-hypervisor-run-diagnostics)
                   (emacs-hypervisor-run-diagnostics))))))
        (error
         (message "HUD: Actor action failed: %S" err))))
    'block))

;; ---------------------------------------------------------------------------
;; Hooks
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--setup-hooks ()
  "Register window events."
  (add-hook 'window-size-change-functions #'emacs-hypervisor-hud--on-parent-resize)
  (add-hook 'focus-in-hook #'emacs-hypervisor-hud--on-parent-focus-in)
  (add-hook 'xwidget-webkit-pre-navigation-functions #'emacs-hypervisor-hud--pre-navigation-hook)
  (add-hook 'kill-emacs-hook #'emacs-hypervisor-hud-cleanup))

(defun emacs-hypervisor-hud--remove-hooks ()
  "Tear down registered window hooks."
  (remove-hook 'window-size-change-functions #'emacs-hypervisor-hud--on-parent-resize)
  (remove-hook 'focus-in-hook #'emacs-hypervisor-hud--on-parent-focus-in)
  (remove-hook 'xwidget-webkit-pre-navigation-functions #'emacs-hypervisor-hud--pre-navigation-hook)
  (remove-hook 'kill-emacs-hook #'emacs-hypervisor-hud-cleanup))

;; ---------------------------------------------------------------------------
;; Session lifecycle
;; ---------------------------------------------------------------------------

(defun emacs-hypervisor-hud--initialize-session ()
  "Create the child frame, check for xwidget support, and load the xwidget webview."
  (let ((parent (selected-frame)))
    (unless (featurep 'xwidget-internal)
      (error "HUD Error: This Emacs binary is not compiled with xwidget support"))

    (unless (frame-live-p emacs-hypervisor-hud--frame)
      (emacs-hypervisor-hud--make-frame parent)
      (emacs-hypervisor-hud--setup-hooks))

    (make-frame-visible emacs-hypervisor-hud--frame)
    (raise-frame emacs-hypervisor-hud--frame)

    (with-selected-frame emacs-hypervisor-hud--frame
      (let* ((window (frame-root-window emacs-hypervisor-hud--frame))
             (orig-buffer (window-buffer window)))

        (with-selected-window window
          (condition-case err
              (let* ((parent-win-config (with-selected-frame emacs-hypervisor-hud--parent-frame (current-window-configuration)))
                     (child-win-config (current-window-configuration))
                     (_ (xwidget-webkit-new-session (emacs-hypervisor-hud--url-with-theme)))
                     (session (xwidget-webkit-current-session))
                     (buf (xwidget-buffer session)))

                (with-selected-frame emacs-hypervisor-hud--parent-frame
                  (set-window-configuration parent-win-config))
                (set-window-configuration child-win-config)

                (setq emacs-hypervisor-hud--session session)

                (with-current-buffer buf
                  (setq-local mode-line-format nil)
                  (setq-local header-line-format nil)
                  (setq-local display-line-numbers nil)
                  (setq-local left-fringe-width 0)
                  (setq-local right-fringe-width 0))

                (set-window-buffer window buf)
                (set-window-dedicated-p window t)

                ;; Only ever kill our own throwaway placeholder (its name starts
                ;; with a space), never a user buffer that happened to be shown.
                (when (and orig-buffer
                           (not (eq orig-buffer buf))
                           (buffer-live-p orig-buffer)
                           (string-prefix-p " " (buffer-name orig-buffer)))
                  (kill-buffer orig-buffer))

                ;; Push theme colors after xwidget loads, then start retrying
                ;; collect until the extension actor is ready.
                (run-with-timer 0.5 nil
                  (lambda ()
                    (emacs-hypervisor-hud--push-theme)
                    (emacs-hypervisor-hud--retry-initial-collect 0)))
                ;; Wire up event-driven triggers
                (emacs-hypervisor-hud--setup-trigger-hooks)
                (message "HUD: Spawned corner HUD overlay session."))

            (error
             (message "HUD: Failed to render xwidget: %S" err)
             (emacs-hypervisor-hud-cleanup))))))
    (emacs-hypervisor-hud--reposition-frame)))

;; ---------------------------------------------------------------------------
;; Public API
;; ---------------------------------------------------------------------------

;;;###autoload
(defun emacs-hypervisor-hud-refresh ()
  "Pull current state from the Elle actor and push it to the WASM renderer.
Use this for initial load or when you suspect the event stream was missed."
  (interactive)
  (condition-case err
      (let ((response (emacs-hypervisor-extension-call :hud :state nil)))
        (when (and response (plist-get response :state))
          (emacs-hypervisor-hud--push-state-to-wasm
           (plist-get response :state))))
    (error
     (message "HUD: Failed to refresh state from actor: %S" err))))

;;;###autoload
(defun emacs-hypervisor-hud-push-state (&optional _state-plist)
  "Trigger a data collection cycle through the Elle actor.
This replaces the old direct :update method — the actor now collects
git data natively via libgit2 when triggered."
  (interactive)
  (emacs-hypervisor-hud--trigger-collect))

;;;###autoload
(defun emacs-hypervisor-hud-show ()
  "Show the corner HUD."
  (interactive)
  (unless emacs-hypervisor-hud--url
    (error "HUD Error: HUD HTML assets URL not set. Is the hypervisor session active?"))

  (if (frame-live-p emacs-hypervisor-hud--frame)
      (progn
        (make-frame-visible emacs-hypervisor-hud--frame)
        (raise-frame emacs-hypervisor-hud--frame)
        (emacs-hypervisor-hud--reposition-frame)
        ;; Trigger collect on re-show to refresh data
        (emacs-hypervisor-hud--trigger-collect)
        (message "Corner HUD displayed."))
    (emacs-hypervisor-hud--initialize-session)))

;;;###autoload
(defun emacs-hypervisor-hud-hide ()
  "Hide the corner HUD."
  (interactive)
  (when (frame-live-p emacs-hypervisor-hud--frame)
    (make-frame-invisible emacs-hypervisor-hud--frame)
    (message "Corner HUD hidden.")))

;;;###autoload
(defun emacs-hypervisor-hud-toggle ()
  "Toggle the corner HUD."
  (interactive)
  (if (and (frame-live-p emacs-hypervisor-hud--frame)
           (frame-visible-p emacs-hypervisor-hud--frame))
      (emacs-hypervisor-hud-hide)
    (emacs-hypervisor-hud-show)))

;;;###autoload
(defun emacs-hypervisor-hud-cleanup ()
  "Tear down corner HUD resources cleanly."
  (interactive)
  (emacs-hypervisor-hud--remove-trigger-hooks)
  (emacs-hypervisor-hud--remove-hooks)
  (when (frame-live-p emacs-hypervisor-hud--frame)
    (delete-frame emacs-hypervisor-hud--frame)
    (setq emacs-hypervisor-hud--frame nil))
  (when emacs-hypervisor-hud--session
    (let ((buf (xwidget-buffer emacs-hypervisor-hud--session)))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions (delq 'xwidget-kill-buffer-query-function kill-buffer-query-functions)))
          (kill-buffer buf))))
    (setq emacs-hypervisor-hud--session nil))
  (message "Corner HUD resources released."))

(provide 'emacs-hypervisor-hud)
(setq emacs-hypervisor-hud-ready t)
;;; emacs-hypervisor-hud.el ends here
