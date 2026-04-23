;;; emacs-hypervisor-report.el --- Startup report UI -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defvar emacs-hypervisor--plan-messages)
(defvar emacs-hypervisor--progress-messages)
(defvar emacs-hypervisor--report-messages)
(defvar emacs-hypervisor--state)
(defvar emacs-hypervisor--last-progress-message)
(defvar emacs-hypervisor--shutdown-reason)
(defvar emacs-hypervisor--completed)

(defvar emacs-hypervisor--report-buffer-name "*emacs-hypervisor-report*")
(defvar emacs-hypervisor--session-started-at nil)
(defvar emacs-hypervisor--session-finished-at nil)
(defvar emacs-hypervisor--package-events nil)
(defvar emacs-hypervisor--unit-events nil)
(defvar emacs-hypervisor--metric-events nil)
(defvar emacs-hypervisor--package-installation-active nil)
(defvar emacs-hypervisor--package-installation-started-at nil)
(defvar emacs-hypervisor--package-finished-reason nil)
(defvar emacs-hypervisor--running-unit-name nil)

(defvar emacs-hypervisor-report-recent-completed-limit 5)

(defface emacs-hypervisor-report-section-title
  '((t (:weight bold)))
  "Face for report section titles."
  :group 'emacs-hypervisor)

(defface emacs-hypervisor-report-running
  '((t (:inherit warning :weight bold)))
  "Face for the currently running config unit."
  :group 'emacs-hypervisor)

(defface emacs-hypervisor-report-completed
  '((t (:inherit warning)))
  "Face for recently completed config units."
  :group 'emacs-hypervisor)

(defface emacs-hypervisor-report-problem
  '((t (:inherit error)))
  "Face for skipped, invalid, or failed config units."
  :group 'emacs-hypervisor)

(defun emacs-hypervisor-report-quit-window ()
  "Quit the report window without surfacing the Elpaca log buffer."
  (interactive)
  (let ((window (selected-window))
        (buffer (current-buffer)))
    (when-let ((elpaca-buffer (get-buffer "*elpaca-log*")))
      (bury-buffer elpaca-buffer))
    (bury-buffer buffer)
    (if (one-window-p t)
        (switch-to-prev-buffer window 'bury)
      (delete-window window))))

(defvar emacs-hypervisor-report-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'emacs-hypervisor-report-quit-window)
    map))

(define-derived-mode emacs-hypervisor-report-mode special-mode "Hypervisor-Report"
  "Major mode for the Hypervisor startup report buffer."
  (setq-local truncate-lines t))

(defun emacs-hypervisor-report-buffer ()
  "Return the Hypervisor startup report buffer."
  (get-buffer-create emacs-hypervisor--report-buffer-name))

(defun emacs-hypervisor--message-payload (message)
  (cdr message))

(defun emacs-hypervisor--find-plan-message (phase)
  (cl-find-if
   (lambda (message)
     (eq (plist-get (emacs-hypervisor--message-payload message) :phase) phase))
   emacs-hypervisor--plan-messages))

(defun emacs-hypervisor--find-report-message (stage phase)
  (cl-find-if
   (lambda (message)
     (let ((payload (emacs-hypervisor--message-payload message)))
       (and (eq (plist-get payload :stage) stage)
            (eq (plist-get payload :phase) phase))))
   emacs-hypervisor--report-messages))

(defun emacs-hypervisor--plan-items (phase)
  (copy-tree
   (or (plist-get
        (emacs-hypervisor--message-payload
         (emacs-hypervisor--find-plan-message phase))
        :items)
       nil)))

(defun emacs-hypervisor--phase-reports (stage phase)
  (copy-tree
   (or (plist-get
        (emacs-hypervisor--message-payload
         (emacs-hypervisor--find-report-message stage phase))
        :items)
       nil)))

(defun emacs-hypervisor--status-counts (reports)
  (list
   :total (length reports)
   :ok (cl-count :ok reports :key (lambda (entry) (plist-get entry :status)))
   :failed (cl-count :failed reports :key (lambda (entry) (plist-get entry :status)))
   :skipped (cl-count :skipped reports :key (lambda (entry) (plist-get entry :status)))
   :invalid (cl-count :invalid reports :key (lambda (entry) (plist-get entry :status)))))

(defun emacs-hypervisor--summary-status (counts)
  (cond
   ((> (plist-get counts :failed) 0) :failed)
   ((> (plist-get counts :invalid) 0) :invalid)
   ((> (plist-get counts :skipped) 0) :skipped)
   (t :ok)))

(defun emacs-hypervisor--startup-summary-status ()
  (emacs-hypervisor--summary-status
   (emacs-hypervisor--status-counts
    (emacs-hypervisor--phase-reports :executed :units))))

(defun emacs-hypervisor--format-elapsed ()
  (let ((started emacs-hypervisor--session-started-at))
    (if (null started)
        "0.00s"
      (format "%.2fs"
              (- (or emacs-hypervisor--session-finished-at (float-time))
                 started)))))

(defun emacs-hypervisor-report-session-elapsed-seconds ()
  "Return the Hypervisor session wall time in seconds."
  (when emacs-hypervisor--session-started-at
    (- (or emacs-hypervisor--session-finished-at (float-time))
       emacs-hypervisor--session-started-at)))

(defun emacs-hypervisor-report-session-elapsed-ms ()
  "Return the Hypervisor session wall time in milliseconds."
  (when-let ((seconds (emacs-hypervisor-report-session-elapsed-seconds)))
    (* 1000.0 seconds)))

(defun emacs-hypervisor--format-duration-ms (duration-ms)
  (format "%.1fms" (or duration-ms 0.0)))

(defun emacs-hypervisor--format-since-start (time)
  (if (null time)
      ""
    (format "%.2fs" (- time (or emacs-hypervisor--session-started-at time)))))

(defun emacs-hypervisor--current-activity ()
  (cond
   (emacs-hypervisor--running-unit-name
    (format "Running %s" emacs-hypervisor--running-unit-name))
   (emacs-hypervisor--package-installation-active
    "Installing packages")
   (emacs-hypervisor--completed
    (pcase (emacs-hypervisor--startup-summary-status)
      (:failed "Finished with failures")
      (:invalid "Finished with invalid units")
      (:skipped "Finished with skipped units")
      (_ "Finished")))
   (emacs-hypervisor--last-progress-message
    (let* ((payload (emacs-hypervisor--message-payload emacs-hypervisor--last-progress-message))
           (phase (plist-get payload :phase))
           (step (plist-get payload :step)))
      (format "%s / %s" (or phase :unknown) (or step :unknown))))
   (t
    "Starting")))

(defun emacs-hypervisor--reason-string (reason)
  (cond
   ((null reason) "")
   ((symbolp reason)
    (pcase reason
      (:blocked-by-package "blocked by package")
      (:blocked-by-unit "blocked by unit")
      (:missing-required-packages "missing required packages")
      (:missing-after-units "missing after units")
      (:preflight "preflight failed")
      (:cycle "dependency cycle")
      (:execution "execution failed")
      (:executed "executed")
      (_ (string-remove-prefix ":" (symbol-name reason)))))
   (t (format "%s" reason))))

(defun emacs-hypervisor--format-detail-list (values)
  (if (and (listp values) values)
      (mapconcat #'identity values ", ")
    ""))

(defun emacs-hypervisor--format-report-details (details)
  (cond
   ((null details) "")
   ((plist-get details :blockers)
    (emacs-hypervisor--format-detail-list
     (plist-get details :blockers)))
   ((plist-get details :missing)
    (emacs-hypervisor--format-detail-list
     (plist-get details :missing)))
   ((or (plist-get details :env) (plist-get details :executable))
    (let ((env (emacs-hypervisor--format-detail-list (plist-get details :env)))
          (executable (emacs-hypervisor--format-detail-list
                       (plist-get details :executable))))
      (format "env: %s, executable: %s"
              (if (string-empty-p env) "-" env)
              (if (string-empty-p executable) "-" executable))))
   ((plist-get details :error)
    (format "%s" (plist-get details :error)))
   (t
    (format "%S" details))))

(defun emacs-hypervisor--format-reason-and-details (reason details)
  (pcase reason
    (:blocked-by-package
     (format "blocked by package: %s"
             (emacs-hypervisor--format-report-details details)))
    (:blocked-by-unit
     (format "blocked by unit: %s"
             (emacs-hypervisor--format-report-details details)))
    (:missing-required-packages
     (format "missing required packages: %s"
             (emacs-hypervisor--format-report-details details)))
    (:missing-after-units
     (format "missing after units: %s"
             (emacs-hypervisor--format-report-details details)))
    (:preflight
     (format "preflight failed: %s"
             (emacs-hypervisor--format-report-details details)))
    (:cycle
     (format "dependency cycle: %s"
             (emacs-hypervisor--format-report-details details)))
    (:execution
     (if (string-empty-p (emacs-hypervisor--format-report-details details))
         "execution failed"
       (format "execution failed: %s"
               (emacs-hypervisor--format-report-details details))))
    (_
     (let ((detail-text (emacs-hypervisor--format-report-details details))
           (reason-text (emacs-hypervisor--reason-string reason)))
       (string-join
        (delq nil
              (list (unless (string-empty-p reason-text) reason-text)
                    (unless (string-empty-p detail-text) detail-text)))
        " | ")))))

(defun emacs-hypervisor--unit-report-basis ()
  (or (emacs-hypervisor--phase-reports :executed :units)
      (emacs-hypervisor--phase-reports :planned :units)
      nil))

(defun emacs-hypervisor--package-report-basis ()
  (or (emacs-hypervisor--phase-reports :executed :packages)
      (emacs-hypervisor--phase-reports :planned :packages)
      nil))

(defun emacs-hypervisor--problem-reports ()
  (seq-filter
   (lambda (report)
     (memq (plist-get report :status) '(:skipped :failed :invalid)))
   (emacs-hypervisor--unit-report-basis)))

(defun emacs-hypervisor--unit-plan-items ()
  (or (emacs-hypervisor--plan-items :units) nil))

(defun emacs-hypervisor--unit-plan-names ()
  (mapcar (lambda (item) (plist-get item :name))
          (emacs-hypervisor--unit-plan-items)))

(defun emacs-hypervisor--recent-completed-events ()
  (cl-loop for event in emacs-hypervisor--unit-events
           when (eq (plist-get event :kind) :success)
           collect event into successes
           finally
           return (cl-subseq successes
                             0
                             (min emacs-hypervisor-report-recent-completed-limit
                                  (length successes)))))

(defun emacs-hypervisor--find-unit-event (name kind)
  (seq-find
   (lambda (event)
     (and (eq (plist-get event :kind) kind)
          (equal (plist-get event :name) name)))
   emacs-hypervisor--unit-events))

(defun emacs-hypervisor--unit-terminal-state-table ()
  (let ((states (make-hash-table :test 'equal)))
    (dolist (event emacs-hypervisor--unit-events states)
      (let ((kind (plist-get event :kind))
            (name (plist-get event :name)))
        (when (and name
                   (memq kind '(:success :failed))
                   (not (gethash name states)))
          (puthash name kind states))))))

(defun emacs-hypervisor--unit-progress-summary ()
  (let* ((plan-names (emacs-hypervisor--unit-plan-names))
         (states (emacs-hypervisor--unit-terminal-state-table))
         (completed
          (cl-loop for name in plan-names
                   count (eq (gethash name states) :success)))
         (failed
          (cl-loop for name in plan-names
                   count (eq (gethash name states) :failed))))
    (list :planned (length plan-names)
          :completed completed
          :failed failed)))

(defun emacs-hypervisor--package-progress-summary ()
  (let* ((reports (emacs-hypervisor--package-report-basis))
         (counts (emacs-hypervisor--status-counts reports))
         (installed
          (cl-count :installed emacs-hypervisor--package-events
                    :key (lambda (entry) (plist-get entry :kind)))))
    (list :installed installed
          :ok (plist-get counts :ok)
          :failed (plist-get counts :failed)
          :skipped (plist-get counts :skipped))))

(defun emacs-hypervisor--report-status-counts ()
  (emacs-hypervisor--status-counts (emacs-hypervisor--unit-report-basis)))

(defun emacs-hypervisor--package-state ()
  (cond
   (emacs-hypervisor--package-installation-active
    "Installing with Elpaca")
   (emacs-hypervisor--package-finished-reason
    (capitalize (format "%s" emacs-hypervisor--package-finished-reason)))
   ((emacs-hypervisor--package-report-basis)
    "Planned")
   (t
    "Waiting")))

(defun emacs-hypervisor-report-metrics ()
  "Return recorded startup metrics in chronological order."
  (reverse (copy-tree emacs-hypervisor--metric-events)))

(defun emacs-hypervisor--metric-total-ms (&rest predicates)
  (cl-loop for metric in emacs-hypervisor--metric-events
           when (cl-every (lambda (predicate) (funcall predicate metric)) predicates)
           sum (or (plist-get metric :duration-ms) 0.0)))

(defun emacs-hypervisor--metrics-for-source (source)
  (seq-filter
   (lambda (metric) (eq (plist-get metric :source) source))
   (emacs-hypervisor-report-metrics)))

(defun emacs-hypervisor--slow-metrics (&optional limit)
  (seq-take
   (sort (emacs-hypervisor-report-metrics)
         (lambda (left right)
           (> (or (plist-get left :duration-ms) 0.0)
              (or (plist-get right :duration-ms) 0.0))))
   (or limit 8)))

(defun emacs-hypervisor--metric-label (metric)
  (let* ((source (plist-get metric :source))
         (name (plist-get metric :name))
         (phase (plist-get metric :phase))
         (op (plist-get metric :op))
         (metric-kind (plist-get metric :metric-kind))
         (item-name (plist-get metric :item-name))
         (parts
          (delq nil
                (list
                 (format "%s/%s" source name)
                 (when phase (format "phase=%s" phase))
                 (when op (format "op=%s" op))
                 (when metric-kind (format "kind=%s" metric-kind))
                 (when item-name (format "item=%s" item-name))))))
    (string-join parts "  ")))

(defun emacs-hypervisor-report-metrics-summary ()
  "Return a compact summary of recorded startup metrics."
  (let* ((session-wall-ms (emacs-hypervisor-report-session-elapsed-ms))
         (elle-ms (emacs-hypervisor--metric-total-ms
                   (lambda (metric) (eq (plist-get metric :source) :elle))))
         (emacs-rpc-ms (emacs-hypervisor--metric-total-ms
                        (lambda (metric) (eq (plist-get metric :source) :emacs-rpc))))
         (emacs-eval-ms (emacs-hypervisor--metric-total-ms
                         (lambda (metric) (eq (plist-get metric :source) :emacs-rpc))
                         (lambda (metric) (eq (plist-get metric :op) :eval))))
         (packages-ms (emacs-hypervisor--metric-total-ms
                       (lambda (metric) (eq (plist-get metric :source) :emacs-runtime))))
         (known-ms (+ elle-ms emacs-rpc-ms packages-ms)))
    (list
     :count (length emacs-hypervisor--metric-events)
     :elle-count (length (emacs-hypervisor--metrics-for-source :elle))
     :emacs-rpc-count (length (emacs-hypervisor--metrics-for-source :emacs-rpc))
     :runtime-count (length (emacs-hypervisor--metrics-for-source :emacs-runtime))
     :session-wall-ms session-wall-ms
     :elle-ms elle-ms
     :emacs-rpc-ms emacs-rpc-ms
     :emacs-eval-ms emacs-eval-ms
     :packages-ms packages-ms
     :known-ms known-ms
     :unattributed-ms (and session-wall-ms (max 0.0 (- session-wall-ms known-ms))))))

(defun emacs-hypervisor--activity-focus-index (plan-names states)
  (or (and emacs-hypervisor--running-unit-name
           (cl-position emacs-hypervisor--running-unit-name
                        plan-names
                        :test #'equal))
      (cl-position-if
       (lambda (name)
         (null (gethash name states)))
       plan-names)
      (max 0 (1- (length plan-names)))))

(defun emacs-hypervisor--insert-section (title)
  (insert (propertize title 'face 'emacs-hypervisor-report-section-title) "\n"))

(defun emacs-hypervisor--insert-status-line (label value &optional face)
  (insert "  "
          (propertize (format "%-10s" label) 'face 'shadow)
          " "
          (if face
              (propertize value 'face face)
            value)
          "\n"))

(defun emacs-hypervisor--insert-banner ()
  (let ((parts (list (emacs-hypervisor--current-activity)
                     (emacs-hypervisor--format-elapsed))))
    (insert (propertize "Hypervisor Startup" 'face '(:weight bold :height 1.15)) "\n")
    (insert (string-join parts "  |  ") "\n\n")))

(defun emacs-hypervisor--insert-unit-activity-line (name state)
  (let* ((running (equal name emacs-hypervisor--running-unit-name))
         (marker
          (cond
           (running "[>]")
           ((eq state :success) "[x]")
           ((eq state :failed) "[!]")
           (t "[ ]")))
         (face
          (cond
           (running 'emacs-hypervisor-report-running)
           ((eq state :failed) 'emacs-hypervisor-report-problem)
           ((eq state :success) 'shadow)
           (t 'shadow)))
         (event (and (memq state '(:success :failed))
                     (emacs-hypervisor--find-unit-event name state)))
         (time (plist-get event :time)))
    (insert "  "
            (propertize marker 'face face)
            " "
            (propertize name 'face face))
    (when time
      (insert (propertize
               (format "  %s" (emacs-hypervisor--format-since-start time))
               'face 'shadow)))
    (insert "\n")))

(defun emacs-hypervisor--insert-packages-section ()
  (let ((progress (emacs-hypervisor--package-progress-summary)))
    (emacs-hypervisor--insert-section "Packages")
    (emacs-hypervisor--insert-status-line
     "Status"
     (emacs-hypervisor--package-state))
    (emacs-hypervisor--insert-status-line
     "Progress"
     (if (and (= (plist-get progress :installed) 0)
              (= (plist-get progress :ok) 0)
              (= (plist-get progress :failed) 0)
              (= (plist-get progress :skipped) 0))
         "No package work yet"
       (format "%d installed, %d ok, %d failed, %d skipped"
               (plist-get progress :installed)
               (plist-get progress :ok)
               (plist-get progress :failed)
               (plist-get progress :skipped))))
    (insert "\n")))

(defun emacs-hypervisor--insert-metrics-section ()
  (let* ((summary (emacs-hypervisor-report-metrics-summary))
         (slow-metrics (emacs-hypervisor--slow-metrics)))
    (when (> (plist-get summary :count) 0)
      (emacs-hypervisor--insert-section "Metrics")
      (when-let ((session-wall-ms (plist-get summary :session-wall-ms)))
        (emacs-hypervisor--insert-status-line
         "Session"
         (emacs-hypervisor--format-duration-ms session-wall-ms)))
      (emacs-hypervisor--insert-status-line
       "Emacs"
       (format "rpc %s, eval %s, pkg %s"
               (emacs-hypervisor--format-duration-ms
                (plist-get summary :emacs-rpc-ms))
               (emacs-hypervisor--format-duration-ms
                (plist-get summary :emacs-eval-ms))
               (emacs-hypervisor--format-duration-ms
                (plist-get summary :packages-ms))))
      (emacs-hypervisor--insert-status-line
       "Elle"
       (emacs-hypervisor--format-duration-ms
        (plist-get summary :elle-ms)))
      (when-let ((unattributed-ms (plist-get summary :unattributed-ms)))
        (emacs-hypervisor--insert-status-line
         "Unattributed"
         (emacs-hypervisor--format-duration-ms unattributed-ms)))
      (when slow-metrics
        (insert "\n")
        (emacs-hypervisor--insert-status-line
         "Slowest"
         "Measured events"))
      (dolist (metric slow-metrics)
        (insert "  "
                (propertize
                 (format "%8s"
                         (emacs-hypervisor--format-duration-ms
                          (plist-get metric :duration-ms)))
                 'face 'shadow)
                "  "
                (emacs-hypervisor--metric-label metric)
                "\n"))
      (insert "\n"))))

(defun emacs-hypervisor--insert-activity-section ()
  (let* ((plan-names (emacs-hypervisor--unit-plan-names))
         (states (emacs-hypervisor--unit-terminal-state-table))
         (progress (emacs-hypervisor--unit-progress-summary))
         (counts (emacs-hypervisor--report-status-counts)))
    (emacs-hypervisor--insert-section "Config Units")
    (cond
     (emacs-hypervisor--package-installation-active
      (emacs-hypervisor--insert-status-line
       "State"
       "Waiting for package installation"))
     ((null plan-names)
      (emacs-hypervisor--insert-status-line
       "Progress"
       (format "0 runnable, %d skipped, %d failed, %d invalid"
               (plist-get counts :skipped)
               (plist-get counts :failed)
               (plist-get counts :invalid))))
     (t
      (emacs-hypervisor--insert-status-line
       "Progress"
       (format "%d/%d completed, %d skipped, %d failed, %d invalid"
               (plist-get progress :completed)
               (plist-get progress :planned)
               (plist-get counts :skipped)
               (plist-get counts :failed)
               (plist-get counts :invalid)))
      (let* ((focus (emacs-hypervisor--activity-focus-index plan-names states))
             (start (if emacs-hypervisor--completed
                        (max 0 (- (length plan-names) 6))
                      (max 0 (- focus 3))))
             (end (if emacs-hypervisor--completed
                      (length plan-names)
                    (min (length plan-names) (+ focus 4)))))
        (cl-loop for index from start below end
                 for name = (nth index plan-names)
                 for state = (gethash name states)
                 do (emacs-hypervisor--insert-unit-activity-line
                     name state)))))
    (insert "\n")))

(defun emacs-hypervisor--insert-problems-section ()
  (let ((problems (emacs-hypervisor--problem-reports)))
    (when problems
      (emacs-hypervisor--insert-section "Problems")
      (dolist (report problems)
        (let ((name (plist-get report :name))
              (status (upcase (emacs-hypervisor--reason-string
                               (plist-get report :status))))
              (reason (plist-get report :reason))
              (details (plist-get report :details)))
          (insert "  "
                  (propertize name 'face 'emacs-hypervisor-report-problem)
                  "\n")
          (insert "    "
                  status
                  "  "
                  (emacs-hypervisor--format-reason-and-details reason details)
                  "\n")))
      (insert "\n"))))

(defun emacs-hypervisor--render-report-buffer ()
  (with-current-buffer (emacs-hypervisor-report-buffer)
    (unless (derived-mode-p 'emacs-hypervisor-report-mode)
      (emacs-hypervisor-report-mode))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (emacs-hypervisor--insert-banner)
      (emacs-hypervisor--insert-metrics-section)
      (emacs-hypervisor--insert-packages-section)
      (emacs-hypervisor--insert-activity-section)
      (emacs-hypervisor--insert-problems-section)
      (goto-char (point-min))))
  nil)

(defun emacs-hypervisor--refresh-report-buffer ()
  (when (or (get-buffer emacs-hypervisor--report-buffer-name)
            (not noninteractive))
    (emacs-hypervisor--render-report-buffer)))

(defun emacs-hypervisor-report-reset ()
  "Reset report UI state for a fresh startup session."
  (setq emacs-hypervisor--session-started-at nil)
  (setq emacs-hypervisor--session-finished-at nil)
  (setq emacs-hypervisor--package-events nil)
  (setq emacs-hypervisor--unit-events nil)
  (setq emacs-hypervisor--metric-events nil)
  (setq emacs-hypervisor--package-installation-active nil)
  (setq emacs-hypervisor--package-installation-started-at nil)
  (setq emacs-hypervisor--package-finished-reason nil)
  (setq emacs-hypervisor--running-unit-name nil)
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-session-started ()
  "Mark the start of a startup session."
  (setq emacs-hypervisor--session-started-at (float-time))
  (setq emacs-hypervisor--session-finished-at nil)
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-session-finished ()
  "Mark the end of a startup session."
  (setq emacs-hypervisor--session-finished-at (float-time))
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-plan ()
  "Refresh the report after a new plan message."
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-progress ()
  "Refresh the report after a new progress message."
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-log ()
  "Refresh the report after a new log message."
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-report ()
  "Refresh the report after a new report message."
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-metric (source name duration-ms &rest details)
  "Record a startup metric for SOURCE and NAME lasting DURATION-MS."
  (push (append (list :source source
                      :name name
                      :duration-ms duration-ms
                      :time (float-time))
                details)
        emacs-hypervisor--metric-events)
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-open-report-buffer ()
  "Display the Hypervisor startup report buffer."
  (interactive)
  (let* ((buffer (emacs-hypervisor-report-buffer))
         (report-window (get-buffer-window buffer t))
         (elpaca-buffer (get-buffer "*elpaca-log*"))
         (elpaca-window (and elpaca-buffer
                             (get-buffer-window elpaca-buffer t))))
    (emacs-hypervisor--render-report-buffer)
    (when elpaca-buffer
      (bury-buffer elpaca-buffer))
    (cond
     (elpaca-window
      (set-window-buffer elpaca-window buffer)
      (set-window-prev-buffers elpaca-window nil)
      (when (and report-window
                 (not (eq report-window elpaca-window))
                 (window-live-p report-window)
                 (not (one-window-p t)))
        (delete-window report-window)))
     (report-window nil)
     (t
      (pop-to-buffer buffer)))))

(defun emacs-hypervisor-report-note-package-event (kind &optional name reason)
  "Record a local package event for the startup report."
  (push (delq nil (list :kind kind
                        :name name
                        :reason reason
                        :time (float-time)))
        emacs-hypervisor--package-events)
  (pcase kind
    (:begin
     (setq emacs-hypervisor--package-installation-active t)
     (setq emacs-hypervisor--package-installation-started-at (float-time))
     (setq emacs-hypervisor--package-finished-reason nil))
    ((or :finished :timeout)
     (setq emacs-hypervisor--package-installation-active nil)
     (setq emacs-hypervisor--package-finished-reason reason)
     (when emacs-hypervisor--package-installation-started-at
       (emacs-hypervisor-report-note-metric
        :emacs-runtime
        :package-installation
        (* 1000.0
           (- (float-time) emacs-hypervisor--package-installation-started-at))
        :metric-kind kind
        :item-name reason)
       (setq emacs-hypervisor--package-installation-started-at nil))
     (unless noninteractive
       (emacs-hypervisor-open-report-buffer))))
  (emacs-hypervisor--refresh-report-buffer))

(defun emacs-hypervisor-report-note-unit-event (kind name &optional error)
  "Record a local config-unit event for the startup report."
  (push (delq nil (list :kind kind
                        :name name
                        :error error
                        :time (float-time)))
        emacs-hypervisor--unit-events)
  (pcase kind
    (:attempt
     (setq emacs-hypervisor--running-unit-name name)
     (unless noninteractive
       (emacs-hypervisor-open-report-buffer)))
    ((or :success :failed)
     (when (equal emacs-hypervisor--running-unit-name name)
       (setq emacs-hypervisor--running-unit-name nil))
     (when (and (eq kind :failed) (not noninteractive))
       (emacs-hypervisor-open-report-buffer))))
  (emacs-hypervisor--refresh-report-buffer))

(provide 'emacs-hypervisor-report)
