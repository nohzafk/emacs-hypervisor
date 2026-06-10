;;; emacs-hypervisor-report.el --- Startup report UI -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-report-core)
(require 'subr-x)

(defvar emacs-hypervisor--plan-messages)
(defvar emacs-hypervisor--progress-messages)
(defvar emacs-hypervisor--report-messages)
(defvar emacs-hypervisor--state)
(defvar emacs-hypervisor--last-progress-message)
(defvar emacs-hypervisor--shutdown-reason)
(defvar emacs-hypervisor--completed)
(defvar emacs-hypervisor--startup-warnings)
(defvar emacs-hypervisor--session-started-at)
(defvar emacs-hypervisor--session-finished-at)

(defvar emacs-hypervisor--report-buffer-name "*emacs-hypervisor-report*")

(defvar emacs-hypervisor-report-recent-completed-limit 5)
(defvar emacs-hypervisor-report-package-window-size 7)

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
  "Quit the report window."
  (interactive)
  (let ((window (selected-window))
        (buffer (current-buffer)))
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

(defun emacs-hypervisor--format-duration-ms (duration-ms)
  (format "%.1fms" (or duration-ms 0.0)))

(defun emacs-hypervisor--format-since-start (time)
  (if (null time)
      ""
    (format "%.2fs" (- time (or emacs-hypervisor--session-started-at time)))))

(defun emacs-hypervisor--format-final-elapsed ()
  (when (and emacs-hypervisor--session-started-at
             emacs-hypervisor--session-finished-at)
    (format "%.2fs"
            (- emacs-hypervisor--session-finished-at
               emacs-hypervisor--session-started-at))))

(defun emacs-hypervisor--final-activity (label preposition)
  (if-let ((elapsed (emacs-hypervisor--format-final-elapsed)))
      (format "%s %s %s" label preposition elapsed)
    label))

(defun emacs-hypervisor--current-activity ()
  (cond
   (emacs-hypervisor--completed
    (if (eq emacs-hypervisor--state :failed)
        (emacs-hypervisor--final-activity "Failed" "after")
      (emacs-hypervisor--final-activity "Finished" "in")))
   (emacs-hypervisor--unit-events
    "Config Units")
   ((or emacs-hypervisor--package-installation-active
        emacs-hypervisor--package-events)
    "Packages")
   ((or emacs-hypervisor--plan-messages
        emacs-hypervisor--progress-messages
        emacs-hypervisor--last-progress-message)
    "Preparing")
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
      (:duplicate-name "duplicate name")
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
   ((plist-get details :deps)
    (emacs-hypervisor--format-detail-list
     (plist-get details :deps)))
   ((or (plist-get details :requires) (plist-get details :after))
    (let ((requires (emacs-hypervisor--format-detail-list
                     (plist-get details :requires)))
          (after (emacs-hypervisor--format-detail-list
                  (plist-get details :after))))
      (mapconcat
       #'identity
       (delq nil
             (list
              (unless (string-empty-p requires)
                (format "requires: %s" requires))
              (unless (string-empty-p after)
                (format "after: %s" after))))
       ", ")))
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
   ((plist-get details :summary)
    (format "%s" (plist-get details :summary)))
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
    (:duplicate-name
     (format "declared %s times"
             (or (plist-get details :occurrences) "multiple")))
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

(defun emacs-hypervisor--package-plan-known-p ()
  (not (null (emacs-hypervisor--find-plan-message :packages))))

(defun emacs-hypervisor--package-plan-items ()
  (if (emacs-hypervisor--package-plan-known-p)
      (emacs-hypervisor--plan-items :packages)
    (or (emacs-hypervisor--package-report-basis) nil)))

(defun emacs-hypervisor--package-plan-names ()
  (mapcar (lambda (item) (plist-get item :name))
          (emacs-hypervisor--package-plan-items)))

(defun emacs-hypervisor--problem-reports ()
  (append
   (when (eq emacs-hypervisor--state :failed)
     (list
      (list
       :name "startup"
       :status :failed
       :reason (or emacs-hypervisor--shutdown-reason :startup)
       :details (list :summary
                      (or (emacs-hypervisor-failure-summary)
                          "startup failed")))))
   (seq-filter
    (lambda (report)
      (memq (plist-get report :status) '(:skipped :failed :invalid)))
    (emacs-hypervisor--package-report-basis))
   (seq-filter
    (lambda (report)
      (memq (plist-get report :status) '(:skipped :failed :invalid)))
    (emacs-hypervisor--unit-report-basis))))

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

(defun emacs-hypervisor--package-terminal-state-table ()
  (let ((states (make-hash-table :test 'equal)))
    (dolist (event emacs-hypervisor--package-events states)
      (let ((kind (plist-get event :kind))
            (name (plist-get event :name)))
        (when (and name
                   (memq kind '(:installed :failed))
                   (not (gethash name states)))
          (puthash name kind states))))))

(defun emacs-hypervisor--package-report-table ()
  (let ((reports (make-hash-table :test 'equal)))
    (dolist (report (emacs-hypervisor--package-report-basis) reports)
      (when-let ((name (plist-get report :name)))
        (puthash name report reports)))))

(defun emacs-hypervisor--package-state-for-name (name states reports)
  (or (gethash name states)
      (let ((report (gethash name reports)))
        (pcase (plist-get report :status)
          (:ok
           (and (eq (plist-get report :reason) :installed)
                :installed))
          (:failed :failed)
          (:skipped :skipped)
          (:invalid :failed)
          (_ nil)))))

(defun emacs-hypervisor--package-report-installed-p (report)
  (and (eq (plist-get report :status) :ok)
       (eq (plist-get report :reason) :installed)))

(defun emacs-hypervisor--package-progress-summary ()
  (let* ((reports (emacs-hypervisor--package-report-basis))
         (plan-known (emacs-hypervisor--package-plan-known-p))
         (plan-names (and plan-known (emacs-hypervisor--package-plan-names)))
         (states (emacs-hypervisor--package-terminal-state-table))
         (report-table (emacs-hypervisor--package-report-table))
         (installed 0)
         (failed 0)
         (skipped 0))
    (dolist (name plan-names)
      (pcase (emacs-hypervisor--package-state-for-name name states report-table)
        (:installed (cl-incf installed))
        (:failed (cl-incf failed))
        (:skipped (cl-incf skipped))))
    (let* ((planned (length plan-names))
           (pending (max 0 (- planned installed failed skipped))))
      (list :plan-known plan-known
            :planned planned
            :installed installed
            :pending pending
            :failed failed
            :skipped skipped
            :all-installed
            (and reports
                 (cl-every #'emacs-hypervisor--package-report-installed-p
                           reports))))))

(defun emacs-hypervisor--latest-package-event-name ()
  (plist-get
   (seq-find
    (lambda (event)
      (and (plist-get event :name)
           (memq (plist-get event :kind) '(:installed :failed))))
    emacs-hypervisor--package-events)
   :name))

(defun emacs-hypervisor--package-focus-index (plan-names states reports)
  (or (when-let ((latest-name (emacs-hypervisor--latest-package-event-name)))
        (cl-position latest-name plan-names :test #'equal))
      (cl-position-if
       (lambda (name)
         (not (emacs-hypervisor--package-state-for-name name states reports)))
       plan-names)
      (max 0 (1- (length plan-names)))))

(defun emacs-hypervisor--find-package-event (name kind)
  (seq-find
   (lambda (event)
     (and (eq (plist-get event :kind) kind)
          (equal (plist-get event :name) name)))
   emacs-hypervisor--package-events))

(defun emacs-hypervisor--format-package-progress (progress)
  (cond
   ((not (plist-get progress :plan-known))
    "Waiting for package plan")
   ((and (= (plist-get progress :planned) 0)
         (plist-get progress :all-installed))
    "All packages already installed")
   ((= (plist-get progress :planned) 0)
    "No package work")
   (t
    (format "%d installed, %d pending, %d failed, %d skipped"
            (plist-get progress :installed)
            (plist-get progress :pending)
            (plist-get progress :failed)
            (plist-get progress :skipped)))))

(defun emacs-hypervisor--report-status-counts ()
  (emacs-hypervisor--status-counts (emacs-hypervisor--unit-report-basis)))

(defun emacs-hypervisor--package-state ()
  (let ((reports (emacs-hypervisor--package-report-basis))
        (executed-reports (emacs-hypervisor--phase-reports :executed :packages)))
    (cond
     (emacs-hypervisor--package-installation-active
      "Installing packages")
     (emacs-hypervisor--package-finished-reason
      (capitalize (format "%s" emacs-hypervisor--package-finished-reason)))
     ((and executed-reports
           (> (length executed-reports) 0)
           (= (plist-get (emacs-hypervisor--status-counts executed-reports) :ok)
              (length executed-reports)))
      "Ready")
     (reports
      "Planned")
     (t
      "Waiting"))))

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
  (insert (propertize "Hypervisor Startup" 'face '(:weight bold :height 1.15)) "\n")
  (insert (emacs-hypervisor--current-activity) "\n\n"))

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

(defun emacs-hypervisor--package-revision-label (event)
  "Return the short revision/lock label for an installed package EVENT."
  (let ((rev (plist-get event :rev))
        (locked (plist-get event :locked)))
    (when (stringp rev)
      (concat (substring rev 0 (min 7 (length rev)))
              (pcase locked
                (:hit " (locked)")
                (:pinned " (pinned)")
                (_ ""))))))

(defun emacs-hypervisor--insert-package-activity-line (name state)
  (let* ((marker
          (pcase state
            (:installed "[x]")
            (:failed "[!]")
            (:skipped "[-]")
            (_ "[ ]")))
         (face
          (pcase state
            (:failed 'emacs-hypervisor-report-problem)
            (:installed 'shadow)
            (:skipped 'shadow)
            (_ 'shadow)))
         (event (and (memq state '(:installed :failed))
                     (emacs-hypervisor--find-package-event name state)))
         (time (plist-get event :time))
         (reason (or (plist-get event :reason) "")))
    (insert "  "
            (propertize marker 'face face)
            " "
            (propertize name 'face face))
    (when-let ((revision (and (eq state :installed)
                              (emacs-hypervisor--package-revision-label event))))
      (insert (propertize (format "  %s" revision) 'face 'shadow)))
    (when time
      (insert (propertize
               (format "  %s" (emacs-hypervisor--format-since-start time))
               'face 'shadow)))
    (when (and (eq state :failed)
               (not (string-empty-p reason)))
      (insert (propertize (format "  %s" reason)
                          'face 'emacs-hypervisor-report-problem)))
    (insert "\n")))

(defun emacs-hypervisor--insert-packages-section ()
  (let ((progress (emacs-hypervisor--package-progress-summary))
        (plan-names (emacs-hypervisor--package-plan-names))
        (states (emacs-hypervisor--package-terminal-state-table))
        (reports (emacs-hypervisor--package-report-table)))
    (emacs-hypervisor--insert-section "Packages")
    (emacs-hypervisor--insert-status-line
     "Status"
     (emacs-hypervisor--package-state))
    (emacs-hypervisor--insert-status-line
     "Progress"
     (emacs-hypervisor--format-package-progress progress))
    (when-let ((orphan-event
                (seq-find (lambda (event)
                            (eq (plist-get event :kind) :orphaned))
                          emacs-hypervisor--package-events)))
      (emacs-hypervisor--insert-status-line
       "Orphaned"
       (format "%s  (M-x emacs-hypervisor-prune-packages)"
               (or (plist-get orphan-event :reason) ""))
       'warning))
    (when plan-names
      (let* ((focus (emacs-hypervisor--package-focus-index plan-names states reports))
             (window-size emacs-hypervisor-report-package-window-size)
             (half (/ window-size 2))
             (start (if emacs-hypervisor--completed
                        (max 0 (- (length plan-names) window-size))
                      (max 0 (- focus half))))
             (end (if emacs-hypervisor--completed
                      (length plan-names)
                    (min (length plan-names) (+ start window-size)))))
        (cl-loop for index from start below end
                 for name = (nth index plan-names)
                 for state = (emacs-hypervisor--package-state-for-name
                              name states reports)
                 do (emacs-hypervisor--insert-package-activity-line
                     name state))))
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

(defun emacs-hypervisor--insert-warnings-section ()
  (when emacs-hypervisor--startup-warnings
    (emacs-hypervisor--insert-section "Warnings")
    (dolist (warning (reverse (copy-sequence emacs-hypervisor--startup-warnings)))
      (insert "  "
              (or (plist-get warning :message) "startup warning")
              "\n"))
    (insert "\n")))

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

(defun emacs-hypervisor--format-source-location (source)
  "Format a declaration SOURCE plist as `config.org · Magit · line 14'."
  (let ((file (plist-get source :file))
        (heading (plist-get source :heading))
        (line (plist-get source :line)))
    (when (stringp file)
      (concat (file-name-nondirectory file)
              (when heading (format " · %s" heading))
              (when line (format " · line %s" line))))))

(defun emacs-hypervisor-report-visit-source (button)
  "Jump to the config source location recorded on BUTTON."
  (let* ((source (button-get button 'emacs-hypervisor-source))
         (file (plist-get source :file))
         (line (plist-get source :line)))
    (if (and (stringp file) (file-exists-p file))
        (progn
          (find-file-other-window file)
          (when (integerp line)
            (goto-char (point-min))
            (forward-line (1- line))))
      (message "Source file not found: %s" file))))

(defun emacs-hypervisor--insert-source-button (source)
  "Insert a clickable source-location line for SOURCE when it has a file."
  (when-let ((label (and source (emacs-hypervisor--format-source-location source))))
    (insert "    ")
    (insert-text-button label
                        'action #'emacs-hypervisor-report-visit-source
                        'emacs-hypervisor-source source
                        'follow-link t
                        'help-echo "mouse-1, RET: visit config source")
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
                  "\n")
          (emacs-hypervisor--insert-source-button
           (plist-get report :source))))
      (insert "\n"))))

(defun emacs-hypervisor--insert-report-contents ()
  (emacs-hypervisor--insert-banner)
  (emacs-hypervisor--insert-warnings-section)
  (emacs-hypervisor--insert-metrics-section)
  (emacs-hypervisor--insert-packages-section)
  (emacs-hypervisor--insert-activity-section)
  (emacs-hypervisor--insert-problems-section))

(defun emacs-hypervisor--render-report-buffer ()
  (let ((target (emacs-hypervisor-report-buffer))
        (source (generate-new-buffer " *emacs-hypervisor-report-render*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (unless (derived-mode-p 'emacs-hypervisor-report-mode)
              (emacs-hypervisor-report-mode)))
          (with-current-buffer source
            (emacs-hypervisor--insert-report-contents))
          (with-current-buffer target
            (let ((inhibit-read-only t)
                  (rendered (with-current-buffer source (buffer-string))))
              (unless (equal (buffer-string) rendered)
                (if (fboundp 'replace-buffer-contents)
                    (replace-buffer-contents source)
                  (erase-buffer)
                  (insert rendered)))
              (goto-char (point-min)))))
      (when (buffer-live-p source)
        (kill-buffer source))))
  nil)

(defun emacs-hypervisor--redisplay-report-buffer ()
  ;; Avoid forced redisplay during rapid startup events; Emacs will repaint the
  ;; report normally, and forcing it makes unchanged banner text visibly flicker.
  nil)

(defun emacs-hypervisor--refresh-report-buffer ()
  (when (or (get-buffer emacs-hypervisor--report-buffer-name)
            (not noninteractive))
    (emacs-hypervisor--render-report-buffer)
    (when (get-buffer-window emacs-hypervisor--report-buffer-name t)
      (emacs-hypervisor--redisplay-report-buffer))))

(defun emacs-hypervisor-open-report-buffer ()
  "Display the Hypervisor startup report buffer."
  (interactive)
  (let* ((buffer (emacs-hypervisor-report-buffer))
         (report-window (get-buffer-window buffer t)))
    (emacs-hypervisor--render-report-buffer)
    (unless report-window
      (pop-to-buffer buffer))
    (emacs-hypervisor--redisplay-report-buffer)))

(provide 'emacs-hypervisor-report)
