;;; agent-shell-darwin-notifications.el --- macOS notifications for agent-shell -*- lexical-binding: t; -*-

(require 'agent-shell)
(require 'map)

(defvar-local backbone/agent-shell-darwin-notify-current-buffer nil
  "When non-nil, notify even if the current agent-shell buffer is selected.")

(defun backbone/agent-shell-darwin-notifications--agent-name (buffer)
  "Return a display name for BUFFER."
  (buffer-name buffer))

(defun backbone/agent-shell-darwin-notifications--describe-stop (stop-reason)
  "Return a short message for STOP-REASON."
  (pcase stop-reason
    ("end_turn" "Finished")
    ("max_tokens" "Reached max token limit")
    ("max_turn_requests" "Exceeded request limit")
    ("refusal" "Refused")
    ("cancelled" "Cancelled")
    ((pred stringp) (format "Stopped: %s" stop-reason))
    (_ "Finished")))

(defun backbone/agent-shell-darwin-notifications--notify (title message)
  "Show a native macOS notification with TITLE and MESSAGE."
  (if (executable-find "terminal-notifier")
      (call-process "terminal-notifier" nil 0 nil
                    "-title" title
                    "-message" message
                    "-sender" "org.gnu.Emacs")
    (call-process "osascript" nil 0 nil
                  "-e" (format "display notification %S with title %S"
                               message title))))

(defun backbone/agent-shell-darwin-notifications--should-notify-p (buffer)
  "Return non-nil when BUFFER should show a notification."
  (or (not (frame-focus-state))
      (not (eq buffer (window-buffer (selected-window))))
      (buffer-local-value 'backbone/agent-shell-darwin-notify-current-buffer buffer)))

(defun backbone/agent-shell-darwin-notifications--handle-event (buffer event)
  "Show a notification for agent-shell EVENT from BUFFER."
  (when (and (eq system-type 'darwin)
             (backbone/agent-shell-darwin-notifications--should-notify-p buffer))
    (let ((data (map-elt event :data))
          (agent (backbone/agent-shell-darwin-notifications--agent-name buffer)))
      (pcase (map-elt event :event)
        ('permission-request
         (backbone/agent-shell-darwin-notifications--notify agent "Permission required"))
        ('turn-complete
         (backbone/agent-shell-darwin-notifications--notify
          agent
          (backbone/agent-shell-darwin-notifications--describe-stop
           (map-elt data :stop-reason))))))))

(defun backbone/agent-shell-darwin-notifications-setup ()
  "Set up macOS notifications for the current `agent-shell' buffer."
  (let ((buffer (current-buffer)))
    (agent-shell-subscribe-to
     :shell-buffer buffer
     :on-event (lambda (event)
                 (backbone/agent-shell-darwin-notifications--handle-event buffer event)))))

(provide 'agent-shell-darwin-notifications)

;;; agent-shell-darwin-notifications.el ends here
