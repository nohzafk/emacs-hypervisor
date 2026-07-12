;;; emacs-hypervisor-bootstrap-test.el --- Bootstrap/runtime regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-bootstrap)

(defconst emacs-hypervisor-test--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defun emacs-hypervisor-test--repo-root ()
  "Return the repository root for the loaded test file."
  (expand-file-name "../.." emacs-hypervisor-test--source-directory))

(defun emacs-hypervisor-test--elle-binary ()
  "Return the Elle binary used by integration-style ERT checks."
  (let ((elle-bin (getenv "ELLE_BIN")))
    (if (and elle-bin (not (string-empty-p elle-bin)))
        elle-bin
      (expand-file-name ".elle/target/release/elle"
                        (emacs-hypervisor-test--repo-root)))))

(defun emacs-hypervisor-test--run-elle-source (source)
  "Run SOURCE through Elle from the repo root.
Return a cons cell of (STATUS . OUTPUT)."
  (let* ((repo-root (emacs-hypervisor-test--repo-root))
         (script (make-temp-file
                  (expand-file-name ".emacs-hypervisor-elle-test-" repo-root)
                  nil
                  ".lisp"))
         (buffer (generate-new-buffer " *emacs-hypervisor-elle-test*"))
         status output)
    (unwind-protect
        (progn
          (with-temp-file script
            (insert source))
          (let ((default-directory repo-root))
            (setq status
                  (process-file (emacs-hypervisor-test--elle-binary)
                                nil
                                buffer
                                nil
                                script)))
          (with-current-buffer buffer
            (setq output (buffer-string)))
          (cons status output))
      (when (file-exists-p script)
        (delete-file script))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defvar emacs-hypervisor-test-runtime-value nil)
(defvar emacs-hypervisor-test-unchanged-counter nil)
(defvar emacs-hypervisor-home-directory nil)

(require 'emacs-hypervisor-session-base)
(require 'emacs-hypervisor-package-bridge)
(require 'emacs-hypervisor-package-runtime)
(require 'emacs-hypervisor-effect-registry)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-kind-hook)
(require 'emacs-hypervisor-effect-kind-advice)
(require 'emacs-hypervisor-effect-kind-keybinding)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-unit-runtime)
(require 'emacs-hypervisor-config-loader)
(require 'emacs-hypervisor-reload-report)
(require 'emacs-hypervisor-reload-policy)
(require 'emacs-hypervisor-compose)
(require 'emacs-hypervisor-report)
(require 'emacs-hypervisor-extensions)
(require 'emacs-hypervisor-markdown-mermaid)

(defvar emacs-hypervisor-config-file nil)
(defvar emacs-hypervisor-config-org-file nil)
(defvar emacs-hypervisor-env-file nil)

(defun emacs-hypervisor-test--request (id op &optional payload)
  `(:rpc
    :protocol :sexp-rpc
    :version 1
    :kind :request
    :id ,id
    :op ,op
    :payload ,payload))

(defun emacs-hypervisor-test--event (topic payload)
  `(:rpc
    :protocol :sexp-rpc
    :version 1
    :kind :event
    :topic ,topic
    :payload ,payload))

(defun emacs-hypervisor-test--response (id ok &optional payload error)
  `(:rpc
    :protocol :sexp-rpc
    :version 1
    :kind :response
    :id ,id
    :ok ,ok
    :payload ,payload
    :error ,error))

(defun emacs-hypervisor-test--unit (name body &optional metadata)
  (let ((entry (list :name name
                     :requires nil
                     :after nil
                     :env nil
                     :executable nil
                     :body body)))
    (while metadata
      (setq entry (plist-put entry (pop metadata) (pop metadata))))
    entry))

(defun emacs-hypervisor-test--report (reports name)
  (cl-find name reports
           :key (lambda (entry) (plist-get entry :name))
           :test #'equal))

(defun emacs-hypervisor-test--eval-home-startup-functions ()
  (let ((source
         (expand-file-name
          "../../host/emacs-kernel/home-startup.el"
          emacs-hypervisor-test--source-directory)))
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (let (form done)
        (while (not done)
          (setq form (read (current-buffer)))
          (cond
           ((and (consp form) (eq (car form) 'cond))
            (setq done t))
           ((and (consp form) (eq (car form) 'defun))
            (eval form t))))))))

(ert-deftest emacs-hypervisor-home-startup-init-metadata-reads-generated-header ()
  (emacs-hypervisor-test--eval-home-startup-functions)
  (let* ((home (file-name-as-directory
                (make-temp-file "emacs-hypervisor-home" t)))
         (init-file (expand-file-name "init.el" home))
         (emacs-hypervisor-home-directory home))
    (unwind-protect
        (progn
          (with-temp-file init-file
            (insert ";;; init.el --- Generated test init\n")
            (insert ";; emacs-hypervisor-generated: t\n")
            (insert ";; emacs-hypervisor-content-hash: fnv1a64:test\n"))
          (let ((metadata (emacs-hypervisor--init-metadata)))
            (should (equal (plist-get metadata :init-file) init-file))
            (should (eq (plist-get metadata :init-generated) t))
            (should (equal (plist-get metadata :init-content-hash)
                           "fnv1a64:test"))))
      (delete-directory home t))))

(ert-deftest emacs-hypervisor-dispatch-rpc-event-records-warning ()
  (let (warnings)
    (emacs-hypervisor-reset)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &optional level buffer-name)
                 (push (list type message level buffer-name) warnings))))
      (let ((noninteractive nil))
        (emacs-hypervisor--dispatch
         (emacs-hypervisor-test--event
          :warning
          '(:kind :bootstrap-hash
                  :level :warning
                  :message "generated init.el is stale"
                  :current-hash "old"
                  :expected-hash "new")))))
    (let ((status (emacs-hypervisor-status)))
      (should (equal (plist-get (car (plist-get status :warnings)) :message)
                     "generated init.el is stale")))
    (should (equal (caar warnings) 'emacs-hypervisor))
    (should (equal (cadar warnings) "generated init.el is stale"))
    (should (eq (caddar warnings) :warning))))

(ert-deftest emacs-hypervisor-events-handle-ignores-unavailable-handler ()
  (let ((emacs-hypervisor-events--handlers
         '((:optional . emacs-hypervisor-events--missing-handler))))
    (should-not
     (emacs-hypervisor-events-handle :optional '(:message "not loaded")))))

(ert-deftest emacs-hypervisor-generated-early-init-loads-fixed-xdg-file ()
  (let* ((xdg-dir (make-temp-file "emacs-hypervisor-xdg" t))
         (config-dir (expand-file-name "emacs-hypervisor" xdg-dir))
         (user-early-init (expand-file-name "early-init.el" config-dir))
         (process-environment (copy-sequence process-environment))
         (emacs-hypervisor-test-runtime-value nil)
         (generated-early-init
          (expand-file-name
           "../../host/emacs-kernel/early-init.el"
           emacs-hypervisor-test--source-directory)))
    (unwind-protect
        (progn
          (setenv "XDG_CONFIG_HOME" xdg-dir)
          (make-directory config-dir t)
          (with-temp-file user-early-init
            (insert "(setq emacs-hypervisor-test-runtime-value :loaded)\n"))
          (load-file generated-early-init)
          (should (eq emacs-hypervisor-test-runtime-value :loaded)))
      (delete-directory xdg-dir t))))

(ert-deftest emacs-hypervisor-config-unit-export-preserves-structured-body ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! vector-unit
    :config
    (setq emacs-hypervisor-test-runtime-value
          [["Open" ("a" "window" ignore)]
           ["Tabs" ("[" "prev tab" ignore) ("]" "next tab" ignore)]]))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal (plist-get unit :name) "vector-unit"))
    (should-not (stringp body))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            [["Open" ("a" "window" ignore)]
                             ["Tabs" ("[" "prev tab" ignore)
                              ("]" "next tab" ignore)]])
                      t)))))

(ert-deftest emacs-hypervisor-config-unit-export-canonicalizes-reader-hostile-ops ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! increment-unit
    :config
    (setq emacs-hypervisor-test-runtime-value
          [(1+ emacs-hypervisor-test-runtime-value)]))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            [(+ emacs-hypervisor-test-runtime-value 1)])
                      t)))))

(ert-deftest emacs-hypervisor-package-export-preserves-local-and-lisp-dir ()
  (emacs-hypervisor-reset-declarations)
  (package! elle-lsp-bridge
    :local "~/projects/lsp-bridge/elle-lsp-bridge"
    :lisp-dir "emacs")
  (let ((package (car (emacs-hypervisor-export-packages))))
    (should (equal (plist-get package :name) "elle-lsp-bridge"))
    (should (equal (plist-get package :local)
                   "~/projects/lsp-bridge/elle-lsp-bridge"))
    (should (equal (plist-get package :lisp-dir) "emacs"))))

(ert-deftest emacs-hypervisor-package-export-does-not-require-packages ()
  (emacs-hypervisor-reset-declarations)
  (package! transient)
  (let ((required nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (push (list feature filename noerror) required)
                 nil))
              ((symbol-function 'package-installed-p)
               (lambda (_package &optional _min-version) nil)))
      (emacs-hypervisor-export-packages))
    (should-not required)))

(ert-deftest emacs-hypervisor-package-export-normalizes-installed-state ()
  (emacs-hypervisor-reset-declarations)
  (package! transient)
  (let ((package-alist '((transient . (:raw descriptor)))))
    (should (eq (plist-get (car (emacs-hypervisor-export-packages))
                           :installed)
                t))))

(ert-deftest emacs-hypervisor-config-unit-export-canonicalizes-backquote ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! backquote-unit
    :config
    (setq emacs-hypervisor-test-runtime-value
          `("Hypervisor" . ,emacs-hypervisor-test-runtime-value)))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            (cons "Hypervisor"
                                  emacs-hypervisor-test-runtime-value))
                      t)))))

(ert-deftest emacs-hypervisor-config-unit-export-lowers-quoted-reader-hostile-data ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! quoted-reader-hostile-data-unit
    :config
    (setq emacs-hypervisor-test-runtime-value
          '(foo {} 1+ (bar . 1-) [1+ {}])))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            (list (quote foo)
                                  (intern "{}")
                                  (intern "1+")
                                  (cons (quote bar) (intern "1-"))
                                  (vector (intern "1+") (intern "{}"))))
                      t)))
    (eval body t)
    (should (equal emacs-hypervisor-test-runtime-value
                   (list 'foo
                         (intern "{}")
                         (intern "1+")
                         (cons 'bar (intern "1-"))
                         (vector (intern "1+") (intern "{}")))))))

(ert-deftest emacs-hypervisor-config-unit-export-canonicalizes-reader-hostile-function-quote ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! reader-hostile-function-quote-unit
    :config
    (setq emacs-hypervisor-test-runtime-value
          (mapcar #'1+ '(1 2))))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            (mapcar (symbol-function (intern "1+"))
                                    (list 1 2)))
                      t)))
    (eval body t)
    (should (equal emacs-hypervisor-test-runtime-value '(2 3)))))

(ert-deftest emacs-hypervisor-config-unit-export-rejects-bare-reader-hostile-symbols ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! bare-reader-hostile-symbol
    :config
    (setq emacs-hypervisor-test-runtime-value 1+))
  (should-error (emacs-hypervisor-export-config-units) :type 'error))

(ert-deftest emacs-hypervisor-runtime-run-unit-evals-structured-body ()
  (setq emacs-hypervisor-test-runtime-value nil)
  (setq emacs-hypervisor-execution-events nil)
  (setq emacs-hypervisor-config-units nil)
  (let ((result
         (emacs-hypervisor-runtime-run-unit
          "structured-unit"
          '(progn
             (setq emacs-hypervisor-test-runtime-value
                   [["Open" ("a" "window" ignore)]
                    ["Tabs" ("[" "prev tab" ignore)
                     ("]" "next tab" ignore)]])
             :ok))))
    (should (eq result :ok))
    (should (equal emacs-hypervisor-test-runtime-value
                   [["Open" ("a" "window" ignore)]
                    ["Tabs" ("[" "prev tab" ignore)
                     ("]" "next tab" ignore)]]))
    (should (member '(:phase :units :event :success :name "structured-unit")
                    emacs-hypervisor-execution-events))))

(ert-deftest emacs-hypervisor-runtime-run-unit-can-resolve-body-by-name ()
  (setq emacs-hypervisor-test-runtime-value nil)
  (setq emacs-hypervisor-execution-events nil)
  (setq emacs-hypervisor-config-units
        '((:name "lookup-unit"
           :requires nil
           :body (progn
                   (setq emacs-hypervisor-test-runtime-value :lookup-ok)
                   :lookup-result))))
  (should (eq (emacs-hypervisor-runtime-run-unit "lookup-unit") :lookup-result))
  (should (eq emacs-hypervisor-test-runtime-value :lookup-ok)))

(ert-deftest emacs-hypervisor-session-active-p-allows-completed-live-process ()
  (let ((emacs-hypervisor--process :fake-process)
        (emacs-hypervisor--state :completed)
        (emacs-hypervisor--completed t))
    (cl-letf (((symbol-function 'processp)
               (lambda (_process) t))
              ((symbol-function 'process-live-p)
               (lambda (_process) t)))
      (should (emacs-hypervisor-live-p))
      (should-not (emacs-hypervisor-session-active-p))))
  (let ((emacs-hypervisor--process :fake-process)
        (emacs-hypervisor--state :running)
        (emacs-hypervisor--completed nil))
    (cl-letf (((symbol-function 'processp)
               (lambda (_process) t))
              ((symbol-function 'process-live-p)
               (lambda (_process) t)))
      (should (emacs-hypervisor-live-p))
      (should (emacs-hypervisor-session-active-p)))))

(ert-deftest emacs-hypervisor-readiness-reports-public-session-state ()
  (let ((emacs-hypervisor--state :running)
        (emacs-hypervisor--completed nil))
    (should (eq (emacs-hypervisor-readiness) 'loading)))
  (let ((emacs-hypervisor--state :completed)
        (emacs-hypervisor--completed t))
    (should (eq (emacs-hypervisor-readiness) 'ready)))
  (let ((emacs-hypervisor--state :failed)
        (emacs-hypervisor--completed t))
    (should (eq (emacs-hypervisor-readiness) 'failed))))

(ert-deftest emacs-hypervisor-selective-reload-diffs-and-runs-only-needed-units ()
  (let* ((emacs-hypervisor-test-runtime-value nil)
         (previous
          (list
           (emacs-hypervisor-test--unit
            "unchanged" '(progn (push 'unchanged emacs-hypervisor-test-runtime-value) t))
           (emacs-hypervisor-test--unit
            "changed" '(progn (push 'old emacs-hypervisor-test-runtime-value) t))
           (emacs-hypervisor-test--unit
            "removed" '(progn (push 'removed emacs-hypervisor-test-runtime-value) t))))
         (current
          (list
           (emacs-hypervisor-test--unit
            "unchanged" '(progn (push 'unchanged emacs-hypervisor-test-runtime-value) t))
           (emacs-hypervisor-test--unit
            "changed" '(progn (push 'changed emacs-hypervisor-test-runtime-value) t))
           (emacs-hypervisor-test--unit
            "new" '(progn (push 'new emacs-hypervisor-test-runtime-value) t))))
         (reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil)))
    (should (equal emacs-hypervisor-test-runtime-value '(new changed)))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "unchanged") :status)
                :skipped))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "unchanged") :action)
                :unchanged))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "changed") :status)
                :ok))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "new") :status)
                :ok))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "removed") :action)
                :removed))))

(defvar emacs-hypervisor-test-hook nil)
(defvar emacs-hypervisor-test-hook-a nil)
(defvar emacs-hypervisor-test-hook-b nil)

(defun emacs-hypervisor-test-hook-old ()
  :old)

(defun emacs-hypervisor-test-hook-new ()
  :new)

(defun emacs-hypervisor-test--effect-function-for-unit (unit)
  (plist-get
   (car (emacs-hypervisor-effect-registry-effects-for-unit unit))
   :function))

(ert-deftest emacs-hypervisor-effect-registry-records-and-retracts-unit-effects ()
  (let ((emacs-hypervisor-effect-registry-current nil)
        (emacs-hypervisor-effect-registry--instance-counter 0)
        (emacs-hypervisor-test-runtime-value nil))
    (emacs-hypervisor-effect-registry-record
     '(:unit "registry-unit"
             :kind :hook
             :target emacs-hypervisor-test-hook
             :function ignore
             :retract
             (setq emacs-hypervisor-test-runtime-value
                   (append emacs-hypervisor-test-runtime-value '(:first)))))
    (emacs-hypervisor-effect-registry-record
     '(:unit "registry-unit"
             :kind :advice
             :target emacs-hypervisor-test-advice-target
             :function ignore
             :retract
             (setq emacs-hypervisor-test-runtime-value
                   (append emacs-hypervisor-test-runtime-value '(:second)))))
    (let ((cleanup
           (emacs-hypervisor-effect-registry-retract-unit "registry-unit")))
      (should (= (length (plist-get cleanup :effects)) 2))
      (should (= (length (plist-get cleanup :cleaned)) 2))
      (should-not (plist-get cleanup :failed))
      (should (equal emacs-hypervisor-test-runtime-value
                     '(:second :first)))
      (should-not
       (emacs-hypervisor-effect-registry-effects-for-unit
        "registry-unit")))))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-previous-hook-effect ()
  (let* ((emacs-hypervisor-test-hook nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         reports
         report)
    (emacs-hypervisor-reset-declarations)
    (config-unit! hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                #'emacs-hypervisor-test-hook-old))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (emacs-hypervisor-reset-declarations)
    (config-unit! hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                #'emacs-hypervisor-test-hook-new))
    (setq current (emacs-hypervisor-export-config-units))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
    (setq report (emacs-hypervisor-test--report reports "hook-unit"))
    (should-not (memq #'emacs-hypervisor-test-hook-old emacs-hypervisor-test-hook))
    (should (memq #'emacs-hypervisor-test-hook-new emacs-hypervisor-test-hook))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count (plist-get report :cleanup)) 1))
    (should-not (plist-member report :restart-recommended))))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-generated-hook-lambda ()
  (let* ((emacs-hypervisor-test-hook nil)
         (emacs-hypervisor-test-runtime-value nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         old-symbol
         new-symbol
         reports
         report
         cleanup)
    (emacs-hypervisor-reset-declarations)
    (config-unit! lambda-hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                (lambda ()
                  (setq emacs-hypervisor-test-runtime-value :old))))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (setq old-symbol
          (emacs-hypervisor-test--effect-function-for-unit
           "lambda-hook-unit"))
    (should (fboundp old-symbol))
    (should (memq old-symbol emacs-hypervisor-test-hook))
    (emacs-hypervisor-reset-declarations)
    (config-unit! lambda-hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                (lambda ()
                  (setq emacs-hypervisor-test-runtime-value :new))))
    (setq current (emacs-hypervisor-export-config-units))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
    (setq new-symbol
          (emacs-hypervisor-test--effect-function-for-unit
           "lambda-hook-unit"))
    (setq report (emacs-hypervisor-test--report reports "lambda-hook-unit"))
    (setq cleanup (plist-get report :cleanup))
    (run-hooks 'emacs-hypervisor-test-hook)
    (should (eq emacs-hypervisor-test-runtime-value :new))
    (should-not (memq old-symbol emacs-hypervisor-test-hook))
    (should (memq new-symbol emacs-hypervisor-test-hook))
    (should-not (fboundp old-symbol))
    (should (fboundp new-symbol))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup) 1))
    (should-not (plist-get cleanup :unsupported))))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-loop-generated-hook-lambdas ()
  (let* ((emacs-hypervisor-test-hook-a nil)
         (emacs-hypervisor-test-hook-b nil)
         (emacs-hypervisor-test-runtime-value nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         old-symbols
         new-symbols
         reports
         report
         cleanup)
    (emacs-hypervisor-reset-declarations)
    (config-unit! loop-hook-unit
      :config
      (dolist (entry '((emacs-hypervisor-test-hook-a . :old-a)
                       (emacs-hypervisor-test-hook-b . :old-b)))
        (let ((value (cdr entry)))
          (add-hook (car entry)
                    (lambda ()
                      (push value emacs-hypervisor-test-runtime-value))))))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (setq old-symbols
          (mapcar (lambda (effect) (plist-get effect :function))
                  (emacs-hypervisor-effect-registry-effects-for-unit
                   "loop-hook-unit")))
    (should (= (length old-symbols) 2))
    (run-hooks 'emacs-hypervisor-test-hook-a)
    (run-hooks 'emacs-hypervisor-test-hook-b)
    (should (equal emacs-hypervisor-test-runtime-value
                   '(:old-b :old-a)))
    (emacs-hypervisor-reset-declarations)
    (config-unit! loop-hook-unit
      :config
      (dolist (entry '((emacs-hypervisor-test-hook-a . :new-a)
                       (emacs-hypervisor-test-hook-b . :new-b)))
        (let ((value (cdr entry)))
          (add-hook (car entry)
                    (lambda ()
                      (push value emacs-hypervisor-test-runtime-value))))))
    (setq current (emacs-hypervisor-export-config-units))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
    (setq report (emacs-hypervisor-test--report reports "loop-hook-unit"))
    (setq cleanup (plist-get report :cleanup))
    (setq new-symbols
          (mapcar (lambda (effect) (plist-get effect :function))
                  (emacs-hypervisor-effect-registry-effects-for-unit
                   "loop-hook-unit")))
    (setq emacs-hypervisor-test-runtime-value nil)
    (run-hooks 'emacs-hypervisor-test-hook-a)
    (run-hooks 'emacs-hypervisor-test-hook-b)
    (should (equal emacs-hypervisor-test-runtime-value
                   '(:new-b :new-a)))
    (dolist (symbol old-symbols)
      (should-not (memq symbol emacs-hypervisor-test-hook-a))
      (should-not (memq symbol emacs-hypervisor-test-hook-b))
      (should-not (fboundp symbol)))
    (dolist (symbol new-symbols)
      (should (fboundp symbol)))
    (should (= (length new-symbols) 2))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup) 2))
    (should-not (plist-get cleanup :unsupported))))

(defun emacs-hypervisor-test-advice-target ()
  :target)

(defun emacs-hypervisor-test-advice-target-a ()
  :target-a)

(defun emacs-hypervisor-test-advice-target-b ()
  :target-b)

(defun emacs-hypervisor-test-advice-old (orig-fn &rest args)
  (apply orig-fn args))

(defun emacs-hypervisor-test-advice-new (orig-fn &rest args)
  (apply orig-fn args))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-previous-advice-effect ()
  (let* ((emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         reports
         report)
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! advice-unit
            :config
            (advice-add 'emacs-hypervisor-test-advice-target
                        :around
                        #'emacs-hypervisor-test-advice-old))
          (setq previous (emacs-hypervisor-export-config-units))
          (eval (plist-get (car previous) :body) t)
          (emacs-hypervisor-reset-declarations)
          (config-unit! advice-unit
            :config
            (advice-add 'emacs-hypervisor-test-advice-target
                        :around
                        #'emacs-hypervisor-test-advice-new))
          (setq current (emacs-hypervisor-export-config-units))
          (setq reports
                (emacs-hypervisor--reload-unit-reports
                 (emacs-hypervisor-selective-reload-diff-units previous current)
                 nil))
          (setq report (emacs-hypervisor-test--report reports "advice-unit"))
          (should-not
           (advice-member-p
            #'emacs-hypervisor-test-advice-old
            'emacs-hypervisor-test-advice-target))
          (should
           (advice-member-p
            #'emacs-hypervisor-test-advice-new
            'emacs-hypervisor-test-advice-target))
          (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count (plist-get report :cleanup)) 1))
          (should-not (plist-member report :restart-recommended)))
      (advice-remove 'emacs-hypervisor-test-advice-target
                     #'emacs-hypervisor-test-advice-old)
      (advice-remove 'emacs-hypervisor-test-advice-target
                     #'emacs-hypervisor-test-advice-new)
      (emacs-hypervisor-reset-declarations))))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-generated-advice-lambda ()
  (let* ((emacs-hypervisor-test-runtime-value nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         old-symbol
         new-symbol
         reports
         report
         cleanup)
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! lambda-advice-unit
            :config
            (advice-add 'emacs-hypervisor-test-advice-target
                        :around
                        (lambda (orig-fn &rest args)
                          (setq emacs-hypervisor-test-runtime-value :old)
                          (apply orig-fn args))))
          (setq previous (emacs-hypervisor-export-config-units))
          (eval (plist-get (car previous) :body) t)
          (setq old-symbol
                (emacs-hypervisor-test--effect-function-for-unit
                 "lambda-advice-unit"))
          (should (fboundp old-symbol))
          (should
           (advice-member-p
            old-symbol
            'emacs-hypervisor-test-advice-target))
          (emacs-hypervisor-reset-declarations)
          (config-unit! lambda-advice-unit
            :config
            (advice-add 'emacs-hypervisor-test-advice-target
                        :around
                        (lambda (orig-fn &rest args)
                          (setq emacs-hypervisor-test-runtime-value :new)
                          (apply orig-fn args))))
          (setq current (emacs-hypervisor-export-config-units))
          (setq reports
                (emacs-hypervisor--reload-unit-reports
                 (emacs-hypervisor-selective-reload-diff-units previous current)
                 nil))
          (setq new-symbol
                (emacs-hypervisor-test--effect-function-for-unit
                 "lambda-advice-unit"))
          (setq report
                (emacs-hypervisor-test--report reports "lambda-advice-unit"))
          (setq cleanup (plist-get report :cleanup))
          (emacs-hypervisor-test-advice-target)
          (should (eq emacs-hypervisor-test-runtime-value :new))
          (should-not
           (advice-member-p
            old-symbol
            'emacs-hypervisor-test-advice-target))
          (should
           (advice-member-p
            new-symbol
            'emacs-hypervisor-test-advice-target))
          (should-not (fboundp old-symbol))
          (should (fboundp new-symbol))
          (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup) 1))
          (should-not (plist-get cleanup :unsupported)))
      (when (bound-and-true-p old-symbol)
        (advice-remove 'emacs-hypervisor-test-advice-target old-symbol))
      (when (bound-and-true-p new-symbol)
        (advice-remove 'emacs-hypervisor-test-advice-target new-symbol))
      (emacs-hypervisor-reset-declarations))))

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-loop-generated-advice-lambdas ()
  (let* ((emacs-hypervisor-test-runtime-value nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         old-symbols
         new-symbols
         reports
         report
         cleanup)
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! loop-advice-unit
            :config
            (dolist (entry '((emacs-hypervisor-test-advice-target-a . :old-a)
                             (emacs-hypervisor-test-advice-target-b . :old-b)))
              (let ((value (cdr entry)))
                (advice-add (car entry)
                            :before
                            (lambda (&rest _args)
                              (push value
                                    emacs-hypervisor-test-runtime-value))))))
          (setq previous (emacs-hypervisor-export-config-units))
          (eval (plist-get (car previous) :body) t)
          (setq old-symbols
                (mapcar (lambda (effect) (plist-get effect :function))
                        (emacs-hypervisor-effect-registry-effects-for-unit
                         "loop-advice-unit")))
          (should (= (length old-symbols) 2))
          (emacs-hypervisor-test-advice-target-a)
          (emacs-hypervisor-test-advice-target-b)
          (should (equal emacs-hypervisor-test-runtime-value
                         '(:old-b :old-a)))
          (emacs-hypervisor-reset-declarations)
          (config-unit! loop-advice-unit
            :config
            (dolist (entry '((emacs-hypervisor-test-advice-target-a . :new-a)
                             (emacs-hypervisor-test-advice-target-b . :new-b)))
              (let ((value (cdr entry)))
                (advice-add (car entry)
                            :before
                            (lambda (&rest _args)
                              (push value
                                    emacs-hypervisor-test-runtime-value))))))
          (setq current (emacs-hypervisor-export-config-units))
          (setq reports
                (emacs-hypervisor--reload-unit-reports
                 (emacs-hypervisor-selective-reload-diff-units previous current)
                 nil))
          (setq report
                (emacs-hypervisor-test--report reports "loop-advice-unit"))
          (setq cleanup (plist-get report :cleanup))
          (setq new-symbols
                (mapcar (lambda (effect) (plist-get effect :function))
                        (emacs-hypervisor-effect-registry-effects-for-unit
                         "loop-advice-unit")))
          (setq emacs-hypervisor-test-runtime-value nil)
          (emacs-hypervisor-test-advice-target-a)
          (emacs-hypervisor-test-advice-target-b)
          (should (equal emacs-hypervisor-test-runtime-value
                         '(:new-b :new-a)))
          (dolist (symbol old-symbols)
            (should-not
             (advice-member-p symbol
                              'emacs-hypervisor-test-advice-target-a))
            (should-not
             (advice-member-p symbol
                              'emacs-hypervisor-test-advice-target-b))
            (should-not (fboundp symbol)))
          (dolist (symbol new-symbols)
            (should (fboundp symbol)))
          (should (= (length new-symbols) 2))
          (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count
                      cleanup)
                     2))
          (should-not (plist-get cleanup :unsupported)))
      (dolist (symbol old-symbols)
        (advice-remove 'emacs-hypervisor-test-advice-target-a symbol)
        (advice-remove 'emacs-hypervisor-test-advice-target-b symbol))
      (dolist (symbol new-symbols)
        (advice-remove 'emacs-hypervisor-test-advice-target-a symbol)
        (advice-remove 'emacs-hypervisor-test-advice-target-b symbol))
      (emacs-hypervisor-reset-declarations))))

(defvar emacs-hypervisor-test-keymap nil)

(defun emacs-hypervisor-test-command-previous ()
  (interactive)
  :previous)

(defun emacs-hypervisor-test-command-old ()
  (interactive)
  :old)

(defun emacs-hypervisor-test-command-new ()
  (interactive)
  :new)

(defun emacs-hypervisor-test-command-external ()
  (interactive)
  :external)

(ert-deftest emacs-hypervisor-effect-aware-reload-cleans-previous-keybinding-effect ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0)
         previous
         current
         reports
         report)
    (emacs-hypervisor-reset-declarations)
    (config-unit! keybinding-unit
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-old))
    (emacs-hypervisor-reset-declarations)
    (config-unit! keybinding-unit
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-new))
    (setq current (emacs-hypervisor-export-config-units))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
    (setq report
          (emacs-hypervisor-test--report reports "keybinding-unit"))
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-new))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count
                (plist-get report :cleanup))
               1))))

(ert-deftest emacs-hypervisor-effect-aware-reload-removed-keybinding-unsets-owned-binding ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0)
         previous
         reports
         report)
    (define-key emacs-hypervisor-test-keymap
                (kbd "C-c h")
                #'emacs-hypervisor-test-command-previous)
    (emacs-hypervisor-reset-declarations)
    (config-unit! keybinding-unit
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-old))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous nil)
           nil))
    (setq report
          (emacs-hypervisor-test--report reports "keybinding-unit"))
    (should (eq (plist-get report :action) :removed))
    (should-not
     (emacs-hypervisor-effect-kind-keybinding--lookup
      emacs-hypervisor-test-keymap
      "C-c h"
      'keymap-set))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count
                (plist-get report :cleanup))
               1))))

(ert-deftest emacs-hypervisor-effect-aware-reload-keybinding-divergence-guard-preserves-external-binding ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0)
         previous
         reports
         report
         warnings)
    (emacs-hypervisor-reset-declarations)
    (config-unit! keybinding-unit
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get (car previous) :body) t)
    (keymap-set emacs-hypervisor-test-keymap
                "C-c h"
                #'emacs-hypervisor-test-command-external)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &optional level buffer-name)
                 (push (list type message level buffer-name) warnings))))
      (setq reports
            (emacs-hypervisor--reload-unit-reports
             (emacs-hypervisor-selective-reload-diff-units previous nil)
             nil)))
    (setq report (emacs-hypervisor-test--report reports "keybinding-unit"))
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-external))
    (should (equal (caar warnings) 'emacs-hypervisor))
    (should (string-match-p "Skipped keybinding cleanup"
                            (cadar warnings)))
    ;; The record that was left in place must not be reported as cleaned.
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count
                (plist-get report :cleanup))
               0))
    (should (= (length (plist-get (plist-get report :cleanup) :diverged)) 1))
    (should (eq (plist-get
                 (car (plist-get (plist-get report :cleanup) :diverged))
                 :status)
                :diverged))))

(ert-deftest emacs-hypervisor-effect-aware-reload-global-set-key-records-keybinding-effect ()
  (let* ((key "C-c H g")
         (key-sequence (kbd key))
         (previous-binding (lookup-key global-map key-sequence))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0))
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! global-keybinding-unit
            :config
            (global-set-key (kbd "C-c H g")
                            #'emacs-hypervisor-test-command-old))
          (let* ((unit (car (emacs-hypervisor-export-config-units)))
                 (body (plist-get unit :body)))
            (eval body t)
            (should (eq (lookup-key global-map key-sequence)
                        #'emacs-hypervisor-test-command-old))
            (should
             (eq (plist-get
                  (car
                   (emacs-hypervisor-effect-registry-effects-for-unit
                    "global-keybinding-unit"))
                  :kind)
                 :keybinding))))
      (define-key global-map key-sequence previous-binding)
      (emacs-hypervisor-reset-declarations))))

(ert-deftest emacs-hypervisor-effect-aware-reload-loop-keybindings-record-one-effect-per-iteration ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0))
    (emacs-hypervisor-reset-declarations)
    (config-unit! loop-keybinding-unit
      :config
      (dolist (entry '(("C-c h a" . emacs-hypervisor-test-command-old)
                       ("C-c h b" . emacs-hypervisor-test-command-new)))
        (keymap-set emacs-hypervisor-test-keymap
                    (car entry)
                    (cdr entry))))
    (let* ((unit (car (emacs-hypervisor-export-config-units)))
           (body (plist-get unit :body)))
      (eval body t)
      (should (= (length
                  (emacs-hypervisor-effect-registry-effects-for-unit
                   "loop-keybinding-unit"))
                 2))
      (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h a")
                  #'emacs-hypervisor-test-command-old))
      (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h b")
                  #'emacs-hypervisor-test-command-new)))))

(ert-deftest emacs-hypervisor-effect-keybinding-shared-binding-survives-first-retraction ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0))
    (emacs-hypervisor-reset-declarations)
    (config-unit! shared-binding-unit-a
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (config-unit! shared-binding-unit-b
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (dolist (unit (emacs-hypervisor-export-config-units))
      (eval (plist-get unit :body) t))
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-old))
    ;; Retracting the first owner keeps the binding for the still-active
    ;; second owner while the record itself counts as cleaned.
    (let ((cleanup (emacs-hypervisor-effect-registry-retract-unit
                    "shared-binding-unit-a")))
      (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup)
                 1))
      (should (null (plist-get cleanup :diverged))))
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-old))
    ;; Retracting the last owner removes the binding without a warning.
    (let ((cleanup (emacs-hypervisor-effect-registry-retract-unit
                    "shared-binding-unit-b")))
      (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup)
                 1))
      (should (null (plist-get cleanup :diverged))))
    (should-not
     (emacs-hypervisor-effect-kind-keybinding--lookup
      emacs-hypervisor-test-keymap
      "C-c h"
      'keymap-set))))

(ert-deftest emacs-hypervisor-effect-aware-reload-does-not-synthesize-opaque-effects ()
  (let* ((emacs-hypervisor-test-runtime-value nil)
         (previous
          (list
           (emacs-hypervisor-test--unit
            "opaque-unit"
            '(progn
               (setq emacs-hypervisor-test-runtime-value :old)
               t))))
         (current
          (list
           (emacs-hypervisor-test--unit
            "opaque-unit"
            '(progn
               (setq emacs-hypervisor-test-runtime-value :new)
               t))))
         (reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
         (report (emacs-hypervisor-test--report reports "opaque-unit"))
         (cleanup (plist-get report :cleanup)))
    (should (eq emacs-hypervisor-test-runtime-value :new))
    (should-not (plist-member report :restart-recommended))
    (should-not (plist-get cleanup :effects))
    (should-not (plist-get cleanup :unsupported))
    (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count cleanup)
               0))))

(ert-deftest emacs-hypervisor-selective-reload-preserves-package-and-after-blocking ()
  (let* ((emacs-hypervisor-test-runtime-value nil)
         (current
          (list
           (emacs-hypervisor-test--unit
            "pending-package"
            '(progn (push 'pending emacs-hypervisor-test-runtime-value) t)
            '(:requires ("new-pkg")))
           (emacs-hypervisor-test--unit
            "fails"
            '(progn (error "boom") t))
           (emacs-hypervisor-test--unit
            "blocked"
            '(progn (push 'blocked emacs-hypervisor-test-runtime-value) t)
            '(:after ("fails")))))
         (reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units nil current)
           '("new-pkg"))))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "pending-package")
                           :reason)
                :pending-package-sync))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "fails") :status)
                :failed))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "blocked") :reason)
                :blocked-by-unit))
    (should-not emacs-hypervisor-test-runtime-value)))

(ert-deftest emacs-hypervisor-selective-reload-reports-cycles ()
  (let* ((current
          (list
           (emacs-hypervisor-test--unit
            "cycle-a" '(progn t) '(:after ("cycle-b")))
           (emacs-hypervisor-test--unit
            "cycle-b" '(progn t) '(:after ("cycle-a")))))
         (reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units nil current)
           nil)))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "cycle-a") :reason)
                :cycle))
    (should (eq (plist-get (emacs-hypervisor-test--report reports "cycle-b") :reason)
                :cycle))))

(ert-deftest emacs-hypervisor-reload-summary-counts-selective-and-effect-fields ()
  (let* ((emacs-hypervisor-test-hook nil)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         previous
         current
         reports
         summary)
    (emacs-hypervisor-reset-declarations)
    (config-unit! unchanged
      :config
      t)
    (config-unit! hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                #'emacs-hypervisor-test-hook-old))
    (config-unit! opaque-unit
      :config
      (setq emacs-hypervisor-test-runtime-value :old))
    (setq previous (emacs-hypervisor-export-config-units))
    (eval (plist-get
           (cl-find "hook-unit" previous
                    :key (lambda (entry) (plist-get entry :name))
                    :test #'equal)
           :body)
          t)
    (emacs-hypervisor-reset-declarations)
    (config-unit! unchanged
      :config
      t)
    (config-unit! hook-unit
      :config
      (add-hook 'emacs-hypervisor-test-hook
                #'emacs-hypervisor-test-hook-new))
    (config-unit! opaque-unit
      :config
      (setq emacs-hypervisor-test-runtime-value :new))
    (config-unit! fails
      :config
      (error "boom"))
    (setq current (emacs-hypervisor-export-config-units))
    (setq reports
          (emacs-hypervisor--reload-unit-reports
           (emacs-hypervisor-selective-reload-diff-units previous current)
           nil))
    (setq summary (emacs-hypervisor--reload-summary reports))
    (should (= (plist-get summary :applied) 2))
    (should (= (plist-get summary :removed) 0))
    (should (= (plist-get summary :skipped-unchanged) 1))
    (should (= (plist-get summary :cleaned) 1))
    (should (= (plist-get summary :failed) 1))
    (should-not (plist-member summary :restart-recommended))))

(ert-deftest emacs-hypervisor-reload-config-skips-unchanged-unit ()
  (let* ((temp-dir (make-temp-file "emacs-hypervisor-reload" t))
         (config-file (expand-file-name "config.el" temp-dir))
         (env-file (expand-file-name "env" temp-dir))
         (emacs-hypervisor-config-file config-file)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--process nil)
         (emacs-hypervisor-test-runtime-value 1))
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! stable
            :config
            (setq emacs-hypervisor-test-runtime-value
                  (1+ emacs-hypervisor-test-runtime-value)))
          (with-temp-file config-file
            (insert "(config-unit! stable\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value\n"
                    "        (1+ emacs-hypervisor-test-runtime-value)))\n"))
          (should (eq (plist-get (emacs-hypervisor-reload-config) :kind)
                      :config-reload))
          (should (= emacs-hypervisor-test-runtime-value 1))
          (should (eq (plist-get
                       (emacs-hypervisor-test--report
                        (plist-get emacs-hypervisor-last-soft-reload-report :reports)
                        "stable")
                       :action)
                      :unchanged)))
      (emacs-hypervisor-reset-declarations)
      (delete-directory temp-dir t))))

(ert-deftest emacs-hypervisor-reload-config-allows-completed-live-session ()
  (let* ((temp-dir (make-temp-file "emacs-hypervisor-reload" t))
         (config-file (expand-file-name "config.el" temp-dir))
         (env-file (expand-file-name "env" temp-dir))
         (emacs-hypervisor-config-file config-file)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--state :completed)
         (emacs-hypervisor--completed t)
         (emacs-hypervisor-test-runtime-value 1))
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! stable
            :config
            (setq emacs-hypervisor-test-runtime-value
                  (1+ emacs-hypervisor-test-runtime-value)))
          (with-temp-file config-file
            (insert "(config-unit! stable\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value\n"
                    "        (1+ emacs-hypervisor-test-runtime-value)))\n"))
          (cl-letf (((symbol-function 'emacs-hypervisor-live-p)
                     (lambda () t)))
            (should (eq (plist-get (emacs-hypervisor-reload-config) :kind)
                        :config-reload)))
          (should (= emacs-hypervisor-test-runtime-value 1)))
      (emacs-hypervisor-reset-declarations)
      (delete-directory temp-dir t))))

(ert-deftest emacs-hypervisor-reload-config-rejects-active-session ()
  (let ((emacs-hypervisor--state :running)
        (emacs-hypervisor--completed nil))
    (cl-letf (((symbol-function 'emacs-hypervisor-live-p)
               (lambda () t)))
      (should-error (emacs-hypervisor-reload-config)
                    :type 'user-error))))

(ert-deftest emacs-hypervisor-config-paths-use-fixed-xdg-config-directory ()
  (let* ((home-dir (make-temp-file "emacs-hypervisor-home" t))
         (xdg-dir (make-temp-file "emacs-hypervisor-xdg" t))
         (config-dir (expand-file-name "emacs-hypervisor" xdg-dir))
         (process-environment (copy-sequence process-environment))
         (user-emacs-directory (file-name-as-directory home-dir))
         (emacs-hypervisor-config-file nil)
         (emacs-hypervisor-config-org-file nil))
    (unwind-protect
        (progn
          (makunbound 'emacs-hypervisor-config-file)
          (makunbound 'emacs-hypervisor-config-org-file)
          (setenv "XDG_CONFIG_HOME" xdg-dir)
          (should (equal (emacs-hypervisor--config-file)
                         (expand-file-name "config.el" config-dir)))
          (should (equal (emacs-hypervisor--config-org-file)
                         (expand-file-name "config.org" config-dir))))
      (delete-directory home-dir t)
      (delete-directory xdg-dir t))))

(ert-deftest emacs-hypervisor-config-paths-fall-back-to-home-config-directory ()
  (let* ((home-dir (make-temp-file "emacs-hypervisor-home" t))
         (runtime-home-dir (make-temp-file "emacs-hypervisor-runtime-home" t))
         (config-dir (expand-file-name ".config/emacs-hypervisor" home-dir))
         (process-environment (copy-sequence process-environment))
         (user-emacs-directory (file-name-as-directory runtime-home-dir))
         (emacs-hypervisor-config-file nil)
         (emacs-hypervisor-config-org-file nil))
    (unwind-protect
        (progn
          (makunbound 'emacs-hypervisor-config-file)
          (makunbound 'emacs-hypervisor-config-org-file)
          (setenv "XDG_CONFIG_HOME" nil)
          (setenv "HOME" home-dir)
          (should (equal (emacs-hypervisor--config-file)
                         (expand-file-name "config.el" config-dir)))
          (should (equal (emacs-hypervisor--config-org-file)
                         (expand-file-name "config.org" config-dir))))
      (delete-directory home-dir t)
      (delete-directory runtime-home-dir t))))

(ert-deftest emacs-hypervisor-explicit-config-files-override-fixed-config-directory ()
  (let* ((home-dir (make-temp-file "emacs-hypervisor-home" t))
         (xdg-dir (make-temp-file "emacs-hypervisor-xdg" t))
         (explicit-el (expand-file-name "other.el" home-dir))
         (explicit-org (expand-file-name "other.org" home-dir))
         (process-environment (copy-sequence process-environment))
         (user-emacs-directory (file-name-as-directory home-dir))
         (emacs-hypervisor-config-file explicit-el)
         (emacs-hypervisor-config-org-file explicit-org))
    (unwind-protect
        (progn
          (setenv "XDG_CONFIG_HOME" xdg-dir)
          (should (equal (emacs-hypervisor--config-file) explicit-el))
          (should (equal (emacs-hypervisor--config-org-file) explicit-org)))
      (delete-directory home-dir t)
      (delete-directory xdg-dir t))))

(ert-deftest emacs-hypervisor-reload-config-selective-reload-cleans-before-apply ()
  (let* ((temp-dir (make-temp-file "emacs-hypervisor-reload" t))
         (config-file (expand-file-name "config.el" temp-dir))
         (env-file (expand-file-name "env" temp-dir))
         (emacs-hypervisor-config-file config-file)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--process nil)
         (emacs-hypervisor-test-hook nil)
         (emacs-hypervisor-test-runtime-value :unset)
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-test-unchanged-counter 0)
         messages)
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (config-unit! stable
            :config
            (setq emacs-hypervisor-test-unchanged-counter
                  (1+ emacs-hypervisor-test-unchanged-counter)))
          (config-unit! hook-unit
            :config
            (add-hook 'emacs-hypervisor-test-hook
                      #'emacs-hypervisor-test-hook-old))
          (eval
           (plist-get
            (cl-find "hook-unit"
                     emacs-hypervisor-config-units
                     :key (lambda (entry) (plist-get entry :name))
                     :test #'equal)
            :body)
           t)
          (with-temp-file config-file
            (insert "(config-unit! stable\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-unchanged-counter\n"
                    "        (1+ emacs-hypervisor-test-unchanged-counter)))\n\n"
                    "(config-unit! hook-unit\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value\n"
                    "        (memq #'emacs-hypervisor-test-hook-old\n"
                    "              emacs-hypervisor-test-hook))\n"
                    "  (add-hook 'emacs-hypervisor-test-hook\n"
                    "            #'emacs-hypervisor-test-hook-new))\n"))
          (let* ((report
                  (cl-letf (((symbol-function 'message)
                             (lambda (format-string &rest args)
                               (push (apply #'format-message
                                            format-string
                                            args)
                                     messages))))
                    (emacs-hypervisor-reload-config)))
                 (reports (plist-get report :reports))
                 (summary (plist-get report :summary))
                 (stable-report
                  (emacs-hypervisor-test--report reports "stable"))
                 (hook-report
                  (emacs-hypervisor-test--report reports "hook-unit")))
            (should (eq (plist-get report :kind)
                        :config-reload))
            (should (= emacs-hypervisor-test-unchanged-counter 0))
            (should-not emacs-hypervisor-test-runtime-value)
            (should-not
             (memq #'emacs-hypervisor-test-hook-old
                   emacs-hypervisor-test-hook))
            (should
             (memq #'emacs-hypervisor-test-hook-new
                   emacs-hypervisor-test-hook))
            (should (eq (plist-get stable-report :action) :unchanged))
            (should (eq (plist-get stable-report :status) :skipped))
            (should (eq (plist-get hook-report :action) :changed))
            (should (eq (plist-get hook-report :status) :ok))
            (should (= (emacs-hypervisor-effect-aware-reload-cleanup-count
                        (plist-get hook-report :cleanup))
                       1))
            (should (= (plist-get summary :applied) 1))
            (should (= (plist-get summary :skipped-unchanged) 1))
            (should (= (plist-get summary :cleaned) 1))
            (setq messages (nreverse messages))
            (should (member "[Hypervisor] Reload started" messages))
            (should
             (member
              "[Hypervisor] Reload cleaned hook emacs-hypervisor-test-hook -> emacs-hypervisor-test-hook-old for hook-unit"
              messages))
            (should
             (member "[Hypervisor] Reload re-applied unit: hook-unit"
                     messages))
            (should
             (member
              "[Hypervisor] Reload: 1 changed applied, 1 unchanged skipped, 1 old effects cleaned."
              messages))))
      (remove-hook 'emacs-hypervisor-test-hook
                   #'emacs-hypervisor-test-hook-old)
      (remove-hook 'emacs-hypervisor-test-hook
                   #'emacs-hypervisor-test-hook-new)
      (emacs-hypervisor-reset-declarations)
      (delete-directory temp-dir t))))

(ert-deftest emacs-hypervisor-reload-config-tangles-config-org ()
  (let* ((temp-dir (make-temp-file "emacs-hypervisor-reload" t))
         (config-file (expand-file-name "config.el" temp-dir))
         (config-org-file (expand-file-name "config.org" temp-dir))
         (tangled-file (expand-file-name ".config.tangled.el" temp-dir))
         (env-file (expand-file-name "env" temp-dir))
         (emacs-hypervisor-config-file config-file)
         (emacs-hypervisor-config-org-file config-org-file)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--process nil)
         (emacs-hypervisor-test-runtime-value 0))
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (with-temp-file config-org-file
            (insert "#+begin_src elisp\n"
                    "(config-unit! from-elisp\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value\n"
                    "        (+ emacs-hypervisor-test-runtime-value 1)))\n"
                    "#+end_src\n"
                    "\n"
                    "#+begin_src emacs-lisp\n"
                    "(config-unit! from-emacs-lisp\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value\n"
                    "        (+ emacs-hypervisor-test-runtime-value 41)))\n"
                    "#+end_src\n"))
          (should-not (file-exists-p config-file))
          (should-not (file-exists-p tangled-file))
          (let ((report (emacs-hypervisor-reload-config)))
            (should (eq (plist-get report :kind) :config-reload))
            (should-not (file-exists-p config-file))
            (should (file-exists-p tangled-file))
            (should
             (emacs-hypervisor-test--report
              (plist-get report :reports) "from-elisp"))
            (should
             (emacs-hypervisor-test--report
              (plist-get report :reports) "from-emacs-lisp"))
            (should (= emacs-hypervisor-test-runtime-value 42))))
      (emacs-hypervisor-reset-declarations)
      (delete-directory temp-dir t))))

(ert-deftest emacs-hypervisor-reload-config-tangles-config-org-from-fixed-config-directory ()
  (let* ((home-dir (make-temp-file "emacs-hypervisor-home" t))
         (xdg-dir (make-temp-file "emacs-hypervisor-xdg" t))
         (config-dir (expand-file-name "emacs-hypervisor" xdg-dir))
         (config-org-file (expand-file-name "config.org" config-dir))
         (tangled-file (expand-file-name ".config.tangled.el" config-dir))
         (env-file (expand-file-name "env" home-dir))
         (process-environment (copy-sequence process-environment))
         (user-emacs-directory (file-name-as-directory home-dir))
         (emacs-hypervisor-config-file nil)
         (emacs-hypervisor-config-org-file nil)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--process nil)
         (emacs-hypervisor-test-runtime-value 0))
    (unwind-protect
        (progn
          (makunbound 'emacs-hypervisor-config-file)
          (makunbound 'emacs-hypervisor-config-org-file)
          (setenv "XDG_CONFIG_HOME" xdg-dir)
          (make-directory config-dir t)
          (emacs-hypervisor-reset-declarations)
          (with-temp-file config-org-file
            (insert "#+begin_src emacs-lisp\n"
                    "(config-unit! from-fixed-config-directory\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value 7))\n"
                    "#+end_src\n"))
          (let ((report (emacs-hypervisor-reload-config)))
            (should (eq (plist-get report :kind) :config-reload))
            (should (file-exists-p tangled-file))
            (should
             (emacs-hypervisor-test--report
              (plist-get report :reports) "from-fixed-config-directory"))
            (should (= emacs-hypervisor-test-runtime-value 7))))
      (emacs-hypervisor-reset-declarations)
      (delete-directory home-dir t)
      (delete-directory xdg-dir t))))

(ert-deftest emacs-hypervisor-reload-config-org-skips-tangle-no-blocks ()
  (let* ((temp-dir (make-temp-file "emacs-hypervisor-reload" t))
         (config-file (expand-file-name "config.el" temp-dir))
         (config-org-file (expand-file-name "config.org" temp-dir))
         (env-file (expand-file-name "env" temp-dir))
         (emacs-hypervisor-config-file config-file)
         (emacs-hypervisor-config-org-file config-org-file)
         (emacs-hypervisor-env-file env-file)
         (emacs-hypervisor--process nil)
         (emacs-hypervisor-test-runtime-value 0))
    (unwind-protect
        (progn
          (emacs-hypervisor-reset-declarations)
          (with-temp-file config-org-file
            (insert "#+begin_src elisp\n"
                    "(config-unit! active\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value 1))\n"
                    "#+end_src\n"
                    "\n"
                    "#+begin_src emacs-lisp :tangle no\n"
                    "(config-unit! skipped\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value 99))\n"
                    "#+end_src\n"))
          (let ((report (emacs-hypervisor-reload-config)))
            (should (eq (plist-get report :kind) :config-reload))
            (should (= emacs-hypervisor-test-runtime-value 1))
            (should-not
             (emacs-hypervisor-test--report
              (plist-get report :reports) "skipped"))))
      (emacs-hypervisor-reset-declarations)
      (delete-directory temp-dir t))))

(ert-deftest emacs-hypervisor-load-envvars-file-updates-runtime-environment ()
  (let* ((path-dir "/tmp/emacs-hypervisor-test-bin")
         (temp-file (make-temp-file "emacs-hypervisor-env" nil ".el"))
         (process-environment (copy-sequence process-environment))
         (exec-path (copy-sequence exec-path))
         (previous-shell-file-name (default-value 'shell-file-name)))
    (unwind-protect
        (progn
          (setq-default shell-file-name "/bin/original-shell")
          (with-temp-file temp-file
            (insert "(\"PATH=/tmp/emacs-hypervisor-test-bin:/usr/bin\" "
                    "\"SHELL=/bin/fish\" "
                    "\"HYPERVISOR_TEST=value\")\n"))
          (should
           (equal
            (emacs-hypervisor-load-envvars-file temp-file)
            '("PATH=/tmp/emacs-hypervisor-test-bin:/usr/bin"
              "SHELL=/bin/fish"
              "HYPERVISOR_TEST=value")))
          (should (equal (getenv "HYPERVISOR_TEST") "value"))
          (should (equal (getenv "SHELL") "/bin/fish"))
          (should (equal (default-value 'shell-file-name)
                         "/bin/original-shell"))
          (should (equal (car exec-path) path-dir))
          (should (equal emacs-hypervisor-loaded-env-file
                         (expand-file-name temp-file))))
      (setq-default shell-file-name previous-shell-file-name)
      (delete-file temp-file))))

(ert-deftest emacs-hypervisor-dispatch-rpc-request-handles-core-ops ()
  (let (sent)
    (emacs-hypervisor-reset)
    (setq emacs-hypervisor-context-function
          (lambda () '(:session-name "test-session" :ui batch)))
    (setq emacs-hypervisor-session-data-function
          (lambda (fields)
            `(:requested ,fields :packages ((:name "core-pkg")))))
    (cl-letf (((symbol-function 'emacs-hypervisor-send)
               (lambda (message)
                 (push message sent))))
      (emacs-hypervisor--dispatch
       (emacs-hypervisor-test--request 1 :hello '(:mode :hypervisor-session)))
      (emacs-hypervisor--dispatch
       (emacs-hypervisor-test--request 2 :boot-context nil))
      (emacs-hypervisor--dispatch
       (emacs-hypervisor-test--request 3 :session-data '(:fields (:packages))))
      (emacs-hypervisor--dispatch
       (emacs-hypervisor-test--request 4 :eval '(:form (+ 40 2)))))
    (setq sent (nreverse sent))
    (should (eq emacs-hypervisor--state :running))
    (should (= (length sent) 4))
    (should (equal (plist-get (cdr (nth 0 sent)) :payload)
                   '(:protocol :sexp-rpc
                               :version 1
                               :mode :session-scoped-subprocess
                               :transport :s-expression)))
    (should (equal (plist-get (cdr (nth 1 sent)) :payload)
                   '(:session-name "test-session" :ui batch)))
    (should (equal (plist-get (cdr (nth 2 sent)) :payload)
                   '(:requested (:packages) :packages ((:name "core-pkg")))))
    (should (equal (plist-get (cdr (nth 3 sent)) :payload) 42))))

(ert-deftest emacs-hypervisor-extension-call-routes-emacs-initiated-response ()
  (let (sent)
    (emacs-hypervisor-reset)
    (setq emacs-hypervisor--process 'fake-process)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (_proc) t))
              ((symbol-function 'process-send-string)
               (lambda (_proc _wire)
                 (push (emacs-hypervisor--make-rpc-request
                        100000
                        :extension-call
                        '(:extension :mermaid
                                     :method :render
                                     :args (:source "flowchart LR; A-->B"
                                            :style :ascii)))
                       sent)
                 (emacs-hypervisor--dispatch
                  (emacs-hypervisor-test--response
                   100000
                   t
                   '(:ok t :kind :text :mime "text/plain" :text "A -> B")))))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _args) nil)))
      (let ((payload (emacs-hypervisor-extension-call
                      :mermaid
                      :render
                      '(:source "flowchart LR; A-->B" :style :ascii)
                      1)))
        (should (equal (plist-get payload :text) "A -> B"))
        (should (null emacs-hypervisor--pending-responses))
        (should (= emacs-hypervisor--next-request-id 100001))
        (should (= (length sent) 1))
        (should (eq (plist-get (cdr (car sent)) :op) :extension-call))))))

(ert-deftest emacs-hypervisor-extension-call-signals-rpc-error ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--process 'fake-process)
  (cl-letf (((symbol-function 'process-live-p)
             (lambda (_proc) t))
            ((symbol-function 'process-send-string)
             (lambda (&rest _args)
               (emacs-hypervisor--dispatch
                (emacs-hypervisor-test--response
                 100000
                 nil
                 nil
                 "extension unavailable: mermaid"))))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _args) nil)))
    (should-error
     (emacs-hypervisor-extension-call
      :mermaid :render '(:source "x" :style :ascii) 1)
     :type 'error)))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-keeps-partial-symbol-prefixes ()
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (message (emacs-hypervisor-test--event
                   :log
                   '(:level :info :message file-name)))
         (wire (concat (emacs-hypervisor--sexp-string message) "\n"))
         (split-at (+ (string-match-p "file-name" wire) 4))
         (first-chunk (substring wire 0 split-at))
         (second-chunk (substring wire split-at))
         received)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-hypervisor--dispatch)
                   (lambda (value)
                     (push value received))))
          (emacs-hypervisor-sexp-rpc-filter nil first-chunk)
          (should (null received))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (equal (buffer-string) first-chunk)))
          (emacs-hypervisor-sexp-rpc-filter nil second-chunk)
          (should (equal (nreverse received) (list message)))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-restores-input-buffer-after-dispatch ()
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (first-message (emacs-hypervisor-test--event
                         :log
                         '(:level :info :message "one")))
         (second-message (emacs-hypervisor-test--event
                          :log
                          '(:level :info :message "two")))
         (wire (concat (emacs-hypervisor--sexp-string first-message) "\n"
                       (emacs-hypervisor--sexp-string second-message) "\n"))
         received)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-hypervisor--dispatch)
                   (lambda (value)
                     (push value received)
                     (let ((report-buffer (emacs-hypervisor-report-buffer)))
                       (with-current-buffer report-buffer
                         (emacs-hypervisor-report-mode)
                         (let ((inhibit-read-only t))
                           (erase-buffer)
                           (insert "not a sexp")))
                       (set-buffer report-buffer)))))
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (should (equal (nreverse received) (list first-message second-message)))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer))
      (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-removes-message-before-dispatch ()
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (message (emacs-hypervisor-test--request 30 :eval '(:form (+ 1 2))))
         (wire (concat (emacs-hypervisor--sexp-string message) "\n"))
         reentered
         received)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-hypervisor--dispatch)
                   (lambda (value)
                     (push value received)
                     (unless reentered
                       (setq reentered t)
                       (emacs-hypervisor-sexp-rpc-filter nil "")))))
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (should (equal received (list message)))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-continues-after-dispatch-error ()
  (emacs-hypervisor-reset)
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (poison (emacs-hypervisor-test--event :warning '(:message "boom")))
         (shutdown (emacs-hypervisor-test--event
                    :shutdown '(:reason :hypervisor-session-complete)))
         (wire (concat (emacs-hypervisor--sexp-string poison) "\n"
                       (emacs-hypervisor--sexp-string shutdown) "\n")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-hypervisor-events--handle-warning)
                   (lambda (_payload) (error "handler exploded"))))
          ;; The poisoned handler must not destroy the queued :shutdown.
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (should emacs-hypervisor--completed)
          (should (eq emacs-hypervisor--state :completed))
          (should (string-match-p "handler exploded"
                                  emacs-hypervisor--last-error-message))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-tolerates-stray-non-rpc-text ()
  (emacs-hypervisor-reset)
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (message (emacs-hypervisor-test--event
                   :log '(:level :info :message "after-stray")))
         (wire (concat "(stray output)\n"
                       (emacs-hypervisor--sexp-string message) "\n")))
    (unwind-protect
        (progn
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (should (equal emacs-hypervisor--last-log-message
                         '(:log :level :info :message "after-stray"))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-sexp-rpc-filter-recovers-after-framing-garbage ()
  (emacs-hypervisor-reset)
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (message (emacs-hypervisor-test--event
                   :log '(:level :info :message "after-garbage")))
         (wire (concat (emacs-hypervisor--sexp-string message) "\n")))
    (unwind-protect
        (progn
          ;; Unreadable framing garbage still erases the buffer and signals.
          (should-error (emacs-hypervisor-sexp-rpc-filter nil ")(\n"))
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string))))
          ;; A later well-formed message is processed normally.
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (should (equal emacs-hypervisor--last-log-message
                         '(:log :level :info :message "after-garbage"))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-eventless-crash-reports-failed-readiness ()
  (emacs-hypervisor-reset)
  (should (eq (emacs-hypervisor-readiness) 'loading))
  (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil)))
    (emacs-hypervisor--sentinel :fake-process "segmentation fault\n"))
  (should (eq emacs-hypervisor--state :failed))
  (should (eq emacs-hypervisor--shutdown-reason :process-exited))
  (should (eq (emacs-hypervisor-readiness) 'failed)))

(ert-deftest emacs-hypervisor-unknown-event-topic-is-logged ()
  (emacs-hypervisor-reset)
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event :mystery-topic '(:x 1)))
  (should (string-match-p
           "Unhandled Hypervisor event topic"
           (plist-get (cdr emacs-hypervisor--last-log-message) :message))))

(ert-deftest emacs-hypervisor-load-envvars-file-tolerates-malformed-file ()
  (let ((file (make-temp-file "emacs-hypervisor-env" nil nil "((\"BAD"))
        warnings)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type msg &rest _args) (push msg warnings))))
            (should (null (emacs-hypervisor-load-envvars-file file t)))
            (should warnings)
            (should (string-match-p "env file" (car warnings))))
          ;; Without NOERROR the malformed file still signals.
          (should-error (emacs-hypervisor-load-envvars-file file)))
      (delete-file file))))

(ert-deftest emacs-hypervisor-load-envvars-file-records-file-for-empty-list ()
  (let ((file (make-temp-file "emacs-hypervisor-env" nil nil "()"))
        (emacs-hypervisor-loaded-env-file nil)
        (emacs-hypervisor-loaded-env-vars :unset))
    (unwind-protect
        (progn
          (emacs-hypervisor-load-envvars-file file t)
          (should (equal emacs-hypervisor-loaded-env-file
                         (expand-file-name file)))
          (should (null emacs-hypervisor-loaded-env-vars)))
      (delete-file file))))

(defun emacs-hypervisor-test--explode ()
  (error "kaboom"))

(ert-deftest emacs-hypervisor-rpc-eval-error-backtrace-includes-failing-frame ()
  (let (sent)
    (cl-letf (((symbol-function 'emacs-hypervisor-send)
               (lambda (message) (push message sent))))
      (emacs-hypervisor--dispatch-rpc-eval
       77 '(emacs-hypervisor-test--explode)))
    (let* ((response (car sent))
           (error-text (plist-get (cdr response) :error)))
      (should (null (plist-get (cdr response) :ok)))
      (should (string-match-p "kaboom" error-text))
      (when (fboundp 'handler-bind)
        ;; The signal-time backtrace names the function inside the form.
        (should (string-match-p "emacs-hypervisor-test--explode"
                                error-text))))))

(ert-deftest emacs-hypervisor-env-file-overrides-binary-resolution ()
  (emacs-hypervisor-test--eval-home-startup-functions)
  ;; A post-env-file EMACS_HYPERVISOR_BIN wins over a stale pre-env hit.
  (let ((process-environment
         (cons "EMACS_HYPERVISOR_BIN=/env/bin/emacs-hypervisor"
               process-environment)))
    (should (equal (emacs-hypervisor--resolve-binary-after-env-load
                    "/stale/emacs-hypervisor")
                   "/env/bin/emacs-hypervisor")))
  ;; When the env file adds nothing, the pre-env result is kept.
  (cl-letf (((symbol-function 'emacs-hypervisor-resolve-binary-now)
             (lambda () nil)))
    (should (equal (emacs-hypervisor--resolve-binary-after-env-load
                    "/stale/emacs-hypervisor")
                   "/stale/emacs-hypervisor"))))

(ert-deftest emacs-hypervisor-env-file-bin-override-flows-to-resolution ()
  (emacs-hypervisor-test--eval-home-startup-functions)
  (let ((file (make-temp-file
               "emacs-hypervisor-env" nil nil
               "(\"EMACS_HYPERVISOR_BIN=/env/bin/emacs-hypervisor\")"))
        (original-process-environment
         (default-value 'process-environment))
        (original-exec-path (default-value 'exec-path)))
    (unwind-protect
        (progn
          (emacs-hypervisor-load-envvars-file file t)
          (should (equal (emacs-hypervisor-resolve-binary-now)
                         "/env/bin/emacs-hypervisor")))
      (setq-default process-environment original-process-environment)
      (setq-default exec-path original-exec-path)
      (delete-file file))))

(ert-deftest emacs-hypervisor-early-init-isolates-user-early-init-errors ()
  (let* ((config-root (make-temp-file "emacs-hypervisor-early-init" t))
         (config-dir (expand-file-name "emacs-hypervisor" config-root))
         (early-init-source
          (expand-file-name "../../host/emacs-kernel/early-init.el"
                            emacs-hypervisor-test--source-directory))
         (user-emacs-directory
          (file-name-as-directory
           (expand-file-name "emacs-home" config-root)))
         (package-user-dir package-user-dir)
         (process-environment
          (cons (concat "XDG_CONFIG_HOME=" config-root)
                process-environment)))
    (unwind-protect
        (progn
          (make-directory config-dir t)
          (with-temp-file (expand-file-name "early-init.el" config-dir)
            (insert "(error \"user early-init boom\")\n"))
          (setq emacs-hypervisor-early-init-error nil)
          ;; The trusted early-init must survive a signaling user early-init
          ;; and record the failure for the session report.
          (load early-init-source nil t)
          (should (bound-and-true-p emacs-hypervisor-early-init-error))
          (should (string-match-p "user early-init boom"
                                  emacs-hypervisor-early-init-error)))
      (delete-directory config-root t))))

(ert-deftest emacs-hypervisor-rpc-eval-routes-details-away-from-transport-buffer ()
  (let* ((emacs-hypervisor--buffer-name " *emacs-hypervisor-filter-test*")
         (emacs-hypervisor--details-buffer-name
          " *emacs-hypervisor-filter-details-test*")
         (message (emacs-hypervisor-test--request
                   31
                   :eval
                   '(:form (progn
                             (princ "detail-output")
                             (current-buffer)))))
         (wire (concat (emacs-hypervisor--sexp-string message) "\n"))
         sent)
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-hypervisor-send)
                   (lambda (message)
                     (push message sent))))
          (emacs-hypervisor-sexp-rpc-filter nil wire)
          (with-current-buffer (get-buffer emacs-hypervisor--buffer-name)
            (should (string-empty-p (buffer-string))))
          (with-current-buffer (get-buffer emacs-hypervisor--details-buffer-name)
            (should (equal (buffer-string) "detail-output")))
          (let ((response (car sent)))
            (should (plist-get (cdr response) :ok))
            (should (eq (plist-get (cdr response) :payload)
                        (get-buffer emacs-hypervisor--details-buffer-name)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--buffer-name)))
        (kill-buffer buffer))
      (when-let ((buffer (get-buffer emacs-hypervisor--details-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-detects-fenced-blocks ()
  (with-temp-buffer
    (insert "# Demo\n\n```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((blocks (emacs-hypervisor-markdown-mermaid--source-blocks)))
      (should (= (length blocks) 1))
      (should (string-match-p "flowchart LR" (nth 4 (car blocks)))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-renders-ascii-overlay ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :ascii))
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (extension method args &optional _timeout)
                   (should (eq extension :mermaid))
                   (should (eq method :render))
                   (should (eq (plist-get args :style) :ascii))
                   (should (equal (plist-get args :options)
                                  '(:layout-engine "mermaid-layered"
                                    :path-simplification "lossless"
                                    :unicode true
                                    :ansi false)))
                   (should (integerp (plist-get (plist-get args :viewport) :width)))
                   '(:ok t :kind :text :mime "text/plain" :text "A --> B"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)
        (should (= (length emacs-hypervisor-markdown-mermaid--overlays) 1))
        (should (string-match-p
                 "A --> B"
                 (overlay-get (car emacs-hypervisor-markdown-mermaid--overlays)
                              'after-string)))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-renders-svg-overlay ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :svg)
          (emacs-hypervisor-markdown-mermaid-image-format :svg))
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (extension method args &optional _timeout)
                   (should (eq extension :mermaid))
                   (should (eq method :render))
                   (should (eq (plist-get args :style) :svg))
                   (should (equal (plist-get args :options)
                                  '(:layout-engine "mermaid-layered"
                                    :path-simplification "lossless"
                                    :unicode true
                                    :ansi false)))
                   '(:ok t :kind :image :mime "image/svg+xml"
                         :svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\"/></svg>"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)
        (let ((display (overlay-get (car emacs-hypervisor-markdown-mermaid--overlays)
                                    'after-string)))
          (should (stringp display))
          (should (get-text-property 1 'display display))
          (should (plist-get
                   (get-text-property
                    1
                    'emacs-hypervisor-markdown-mermaid-render
                    display)
                   :svg)))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-click-opens-selected-preview ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  First-->A\n```\n\n")
    (insert "```mermaid\nflowchart LR\n  Second-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :svg)
          (emacs-hypervisor-markdown-mermaid-image-format :svg)
          (count 0)
          opened-render)
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (_extension _method _args &optional _timeout)
                   (setq count (1+ count))
                   (list :ok t
                         :kind :image
                         :mime "image/svg+xml"
                         :svg (format "<svg id=\"diagram-%d\"/>" count))))
                ((symbol-function 'emacs-hypervisor-markdown-mermaid--open-render)
                 (lambda (render)
                   (setq opened-render render))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)
        (should (= (length emacs-hypervisor-markdown-mermaid--overlays) 2))
        (let* ((first-overlay (car (last emacs-hypervisor-markdown-mermaid--overlays)))
               (display (overlay-get first-overlay 'after-string))
               (event '(mouse-1 fake-position)))
          (cl-letf (((symbol-function 'event-end)
                     (lambda (_event) 'fake-position))
                    ((symbol-function 'posn-string)
                     (lambda (_position) (cons display 1)))
                    ((symbol-function 'posn-point)
                     (lambda (_position) (overlay-start first-overlay))))
            (emacs-hypervisor-markdown-mermaid-open-viewer-at-mouse event))
          (should (string-match-p "diagram-1"
                                  (plist-get opened-render :svg))))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-svg-preview-is-bounded ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :svg)
          (emacs-hypervisor-markdown-mermaid-image-format :svg)
          (emacs-hypervisor-markdown-mermaid-preview-max-width 320)
          (emacs-hypervisor-markdown-mermaid-preview-max-height 180)
          create-image-args)
      (cl-letf (((symbol-function 'image-type-available-p)
                 (lambda (type)
                   (should (eq type 'svg))
                   t))
                ((symbol-function 'create-image)
                 (lambda (&rest args)
                   (setq create-image-args args)
                   (append '(image :type svg) (nthcdr 3 args))))
                ((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (_extension _method args &optional _timeout)
                   (should (eq (plist-get args :style) :svg))
                   '(:ok t :kind :image :mime "image/svg+xml"
                         :svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)
        (let* ((overlay (car emacs-hypervisor-markdown-mermaid--overlays))
               (render (overlay-get overlay
                                    'emacs-hypervisor-markdown-mermaid-render))
               (image (plist-get render :preview-image))
               (properties (nthcdr 3 create-image-args)))
          (should (eq (plist-get render :kind) 'image))
          (should (eq (overlay-get overlay 'keymap)
                      emacs-hypervisor-markdown-mermaid-preview-map))
          (should (eq (plist-get properties :keymap)
                      emacs-hypervisor-markdown-mermaid-preview-map))
          (should-not (keymap-lookup
                       emacs-hypervisor-markdown-mermaid-preview-map
                       "RET"))
          (should (eq (keymap-lookup
                       emacs-hypervisor-markdown-mermaid-preview-map
                       "<mouse-1>")
                      #'emacs-hypervisor-markdown-mermaid-open-viewer-at-mouse))
          (should (= (plist-get properties :max-width) 320))
          (should (= (plist-get properties :max-height) 180))
          (should (= (plist-get properties :scale) 1))
          (should (eq image (get-text-property
                             1
                             'display
                             (overlay-get overlay 'after-string)))))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-preview-retries-without-max-height ()
  (let ((emacs-hypervisor-markdown-mermaid-preview-max-width 320)
        (emacs-hypervisor-markdown-mermaid-preview-max-height 180)
        calls)
    (cl-letf (((symbol-function 'create-image)
               (lambda (&rest args)
                 (push args calls)
                 (if (= (length calls) 1)
                     (error "backend rejected :max-height")
                   (append '(image :type svg) (nthcdr 3 args))))))
      (let ((image (emacs-hypervisor-markdown-mermaid--create-preview-image
                    "<svg/>"
                    'svg
                    t)))
        (should image)
        (should (= (length calls) 2))
        (should-not (plist-member (nthcdr 3 (car calls)) :max-height))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-preview-defaults-to-fill-column ()
  (let ((emacs-hypervisor-markdown-mermaid-preview-max-width 'fill-column)
        (emacs-hypervisor-markdown-mermaid-preview-max-height 0.30)
        (fill-column 72))
    (cl-letf (((symbol-function 'frame-char-width)
               (lambda (&rest _args) 10))
              ((symbol-function 'emacs-hypervisor-markdown-mermaid--window-pixel-height)
               (lambda () 900)))
      (should (= (emacs-hypervisor-markdown-mermaid--preview-max-width) 720))
      (should (= (emacs-hypervisor-markdown-mermaid--preview-max-height) 270)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-render-options-are-configurable ()
  (let ((emacs-hypervisor-markdown-mermaid-layout-engine "flux-layered")
        (emacs-hypervisor-markdown-mermaid-edge-preset "basis")
        (emacs-hypervisor-markdown-mermaid-path-simplification "minimal")
        (emacs-hypervisor-markdown-mermaid-theme nil)
        (emacs-hypervisor-markdown-mermaid-theme-mode :dynamic))
    (should (equal (emacs-hypervisor-markdown-mermaid--render-options)
                   '(:layout-engine "flux-layered"
                     :edge-preset "basis"
                     :path-simplification "minimal"
                     :theme-mode "dynamic"
                     :unicode true
                     :ansi false)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-viewer-zoom-keys-find-image ()
  (with-temp-buffer
    (let (zoom-position)
      (insert (propertize " " 'display '(image :type svg)))
      (insert "\n")
      (goto-char (point-max))
      (cl-letf (((symbol-function 'image-increase-size)
                 (lambda (_n position)
                   (setq zoom-position position))))
        (emacs-hypervisor-markdown-mermaid-viewer-zoom-in)
        (should (= zoom-position (point-min)))
        (should (= (point) (point-min)))))
    (should (eq (keymap-lookup
                 emacs-hypervisor-markdown-mermaid-viewer-mode-map
                 "=")
                #'emacs-hypervisor-markdown-mermaid-viewer-zoom-in))))

(ert-deftest emacs-hypervisor-markdown-mermaid-open-viewer-writes-cache ()
  (skip-unless (image-type-available-p 'svg))
  (let ((temporary-file-directory (make-temp-file "hv-mermaid-test-" t)))
    (unwind-protect
        (with-temp-buffer
          (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
          (let* ((emacs-hypervisor-markdown-mermaid-image-format :svg)
                 (block (car (emacs-hypervisor-markdown-mermaid--source-blocks)))
                 (render (emacs-hypervisor-markdown-mermaid--render-object
                          '(:ok t :kind :image :mime "image/svg+xml"
                                :svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>")
                          block))
                 viewer)
            (cl-letf (((symbol-function
                        'emacs-hypervisor-markdown-mermaid-viewer-mode)
                       (lambda ()
                         (setq major-mode
                               'emacs-hypervisor-markdown-mermaid-viewer-mode))))
              (setq viewer (emacs-hypervisor-markdown-mermaid--viewer-buffer
                            render))
              (with-current-buffer viewer
                (should (eq major-mode
                            'emacs-hypervisor-markdown-mermaid-viewer-mode))
                (should buffer-read-only)
                (should-not (buffer-modified-p))
                (should (string-match-p "\\+/= zoom in"
                                        (format "%s" header-line-format)))
                (should (eq emacs-hypervisor-markdown-mermaid-viewer-source-buffer
                            (plist-get render :source-buffer)))
                (should (file-exists-p
                         emacs-hypervisor-markdown-mermaid-viewer-cache-file))
                (should (string-prefix-p
                         (expand-file-name "emacs-hypervisor/mermaid/"
                                           temporary-file-directory)
                         emacs-hypervisor-markdown-mermaid-viewer-cache-file)))
              (kill-buffer viewer))))
      (delete-directory temporary-file-directory t))))

(ert-deftest emacs-hypervisor-markdown-mermaid-refresh-viewer-rerenders-source ()
  (skip-unless (image-type-available-p 'svg))
  (let ((temporary-file-directory (make-temp-file "hv-mermaid-test-" t)))
    (unwind-protect
        (let (source-seen)
          (with-temp-buffer
            (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
            (let* ((emacs-hypervisor-markdown-mermaid-image-format :svg)
                   (block (car (emacs-hypervisor-markdown-mermaid--source-blocks)))
                   (render (emacs-hypervisor-markdown-mermaid--write-cache-file
                            (emacs-hypervisor-markdown-mermaid--render-object
                             '(:ok t :kind :image :mime "image/svg+xml"
                                   :svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg>")
                             block)))
                   viewer)
              (cl-letf (((symbol-function
                          'emacs-hypervisor-markdown-mermaid-viewer-mode)
                         (lambda ()
                           (setq major-mode
                                 'emacs-hypervisor-markdown-mermaid-viewer-mode)))
                        ((symbol-function 'emacs-hypervisor-extension-call)
                         (lambda (_extension _method args &optional _timeout)
                           (setq source-seen (plist-get args :source))
                           (should (equal (plist-get args :options)
                                          '(:layout-engine "mermaid-layered"
                                            :path-simplification "lossless"
                                            :unicode true
                                            :ansi false)))
                           '(:ok t :kind :image :mime "image/svg+xml"
                                 :svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"9\" height=\"9\"></svg>"))))
                (setq viewer (emacs-hypervisor-markdown-mermaid--viewer-buffer
                              render))
                (with-current-buffer viewer
                  (emacs-hypervisor-markdown-mermaid-refresh-viewer)
                  (should (string-match-p "flowchart LR" source-seen))
                  (should-not (string-match-p "```" source-seen))))
              (kill-buffer viewer))))
      (delete-directory temporary-file-directory t))))

(ert-deftest emacs-hypervisor-markdown-mermaid-cleanup-removes-cache-directory ()
  (let ((temporary-file-directory (make-temp-file "hv-mermaid-test-" t)))
    (unwind-protect
        (let ((directory (emacs-hypervisor-markdown-mermaid--cache-directory)))
          (write-region "<svg/>" nil (expand-file-name "one.svg" directory)
                        nil
                        'silent)
          (should (file-directory-p directory))
          (emacs-hypervisor-markdown-mermaid--cleanup-cache)
          (should-not (file-exists-p directory)))
      (when (file-directory-p temporary-file-directory)
        (delete-directory temporary-file-directory t)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-render-style-accepts-common-forms ()
  (let ((emacs-hypervisor-markdown-mermaid-image-format :svg))
    (cl-letf (((symbol-function 'image-type-available-p)
               (lambda (type)
                 (should (eq type 'svg))
                 t)))
      (dolist (style '(:auto auto "auto" :svg svg "svg"))
        (let ((emacs-hypervisor-markdown-mermaid-render-style style))
          (should (eq (emacs-hypervisor-markdown-mermaid--render-style) :svg))))))
  (dolist (style '(:ascii ascii "ascii"))
    (let ((emacs-hypervisor-markdown-mermaid-render-style style))
      (should (eq (emacs-hypervisor-markdown-mermaid--render-style) :ascii)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-auto-falls-back-to-ascii-without-svg ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :auto))
      (cl-letf (((symbol-function 'image-type-available-p)
                 (lambda (type)
                   (should (eq type 'svg))
                   nil))
                ((symbol-function 'executable-find)
                 (lambda (&rest _args) nil))
                ((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (_extension _method args &optional _timeout)
                   (should (eq (plist-get args :style) :ascii))
                   '(:ok t :kind :text :mime "text/plain" :text "rendered"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-viewport-uses-visible-width ()
  (with-temp-buffer
    (insert "    ```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :ascii))
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _args) 'visible-window))
                ((symbol-function 'window-text-width)
                 (lambda (window)
                   (should (eq window 'visible-window))
                   54))
                ((symbol-function 'window-body-width)
                 (lambda (&rest _args) 62))
                ((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (_extension _method args &optional _timeout)
                   (should (= (plist-get (plist-get args :viewport) :width) 54))
                   '(:ok t :kind :text :mime "text/plain" :text "rendered"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-renders-error-payload ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-render-style :ascii))
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (_extension _method args &optional _timeout)
                   (should (eq (plist-get args :style) :ascii))
                   '(:ok false :error :invalid-request :message "bad style"))))
        (emacs-hypervisor-markdown-mermaid-render-buffer)
        (should (string-match-p
                 "bad style"
                 (overlay-get (car emacs-hypervisor-markdown-mermaid--overlays)
                              'after-string)))))))

(ert-deftest emacs-hypervisor-markdown-mermaid-refresh-command-rerenders-buffer ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((render-count 0))
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (&rest _args)
                   (setq render-count (1+ render-count))
                   '(:ok t :kind :text :mime "text/plain" :text "rendered"))))
        (emacs-hypervisor-markdown-mermaid-mode 1)
        (should (= render-count 1))
        (should (eq (keymap-lookup emacs-hypervisor-markdown-mermaid-mode-map "C-c C-r")
                    #'emacs-hypervisor-markdown-mermaid-refresh))
        (emacs-hypervisor-markdown-mermaid-refresh)
        (should (= render-count 2))
        (emacs-hypervisor-markdown-mermaid-mode -1)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-edits-schedule-refresh ()
  (with-temp-buffer
    (insert "```mermaid\nflowchart LR\n  A-->B\n```\n")
    (let ((emacs-hypervisor-markdown-mermaid-auto-refresh-delay 0.2)
          scheduled-delay
          scheduled-buffer)
      (cl-letf (((symbol-function 'emacs-hypervisor-extension-call)
                 (lambda (&rest _args)
                   '(:ok t :kind :text :mime "text/plain" :text "rendered")))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (secs _repeat function buffer)
                   (setq scheduled-delay secs)
                   (setq scheduled-buffer buffer)
                   (list :timer function buffer))))
        (emacs-hypervisor-markdown-mermaid-mode 1)
        (goto-char (point-min))
        (insert "\n")
        (should (= scheduled-delay 0.2))
        (should (eq scheduled-buffer (current-buffer)))
        (emacs-hypervisor-markdown-mermaid-mode -1)))))

(ert-deftest emacs-hypervisor-markdown-mermaid-mmdflux-renders-quoted-edge-label ()
  (let ((elle-bin (emacs-hypervisor-test--elle-binary)))
    (unless (file-executable-p elle-bin)
      (ert-skip (format "Elle binary is unavailable: %s" elle-bin))))
  (let* ((source
          (string-join
           '("(include-file \"elle/extensions.lisp\")"
             "(include-file \"elle/extension-mermaid.lisp\")"
             "(def protocol {:plist-get (fn [_payload _key] nil)})"
             "(def extensions (emacs-hypervisor-extensions-module protocol))"
             "(def mermaid-extension (emacs-hypervisor-mermaid-extension-module extensions))"
             "(let [[ok? mmdflux] (protect (import \"plugin/mmdflux\"))]"
             "  (if (not ok?)"
             "    (begin"
             "      (println (string \"SKIP mmdflux unavailable: \" mmdflux))"
             "      (exit 77))"
             "    (let [payload (mermaid-extension:render mmdflux"
             "                    {:source \"flowchart TD\\n  Kernel <-- \\\"sexp-rpc over stdio\\\" --> Elle\\n\""
             "                     :style :svg"
             "                     :viewport {:width 72}})]"
             "      (if (and (= (get payload :ok) true)"
             "               (= (get payload :kind) :image)"
             "               (= (get payload :mime) \"image/svg+xml\")"
             "               (string/contains? (get payload :svg) \"<svg\")"
             "               (string/contains? (get payload :svg) \"transform=\\\"translate(\"))"
             "        (println \"OK\")"
             "        (begin"
             "          (println (string \"FAIL \" payload))"
             "          (exit 1))))))")
           "\n"))
         (result (emacs-hypervisor-test--run-elle-source source))
         (status (car result))
         (output (cdr result)))
    (cond
     ((equal status 77)
      (ert-skip (string-trim output)))
     ((not (equal status 0))
      (ert-fail (format "Elle mmdflux render failed with status %S:\n%s"
                        status
                        output)))
     (t
      (should (string-match-p "\\bOK\\b" output))))))

(ert-deftest emacs-hypervisor-dispatch-rpc-event-records-session-state ()
  (emacs-hypervisor-reset)
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :plan
    '(:phase :packages :items ((:name "core-pkg" :deps nil)))))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :progress
    '(:phase :startup :step :loaded :done 1 :total 2)))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :log
    '(:level :info :message "hello")))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :report
    '(:stage :planned :phase :packages :items ((:name "core-pkg")))))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :shutdown
    '(:reason :hypervisor-session-complete)))
  (should (equal (car emacs-hypervisor--plan-messages)
                 '(:plan :phase :packages :items ((:name "core-pkg" :deps nil)))))
  (should (equal emacs-hypervisor--last-progress-message
                 '(:progress :phase :startup :step :loaded :done 1 :total 2)))
  (should (equal emacs-hypervisor--last-log-message
                 '(:log :level :info :message "hello")))
  (should (= (length emacs-hypervisor--report-messages) 1))
  (should (eq emacs-hypervisor--shutdown-reason :hypervisor-session-complete))
  (should emacs-hypervisor--completed)
  (should (eq emacs-hypervisor--state :completed)))

(ert-deftest emacs-hypervisor-report-banner-hides-wire-progress-events ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--last-progress-message
        '(:progress :phase :planning :step :plans-emitted :done 5 :total 10))
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote "Hypervisor Startup\nPreparing")
                     contents))
            (should-not (string-match-p
                         (regexp-quote ":planning / :plans-emitted")
                         contents))
            (should-not (string-match-p
                         (regexp-quote "Planning: plans emitted")
                         contents))
            (should-not (string-match-p
                         (regexp-quote "Event")
                         contents)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-banner-shows-stage-not-details ()
  (unwind-protect
      (progn
        (emacs-hypervisor-reset)
        (setq emacs-hypervisor--package-installation-active t)
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote "Hypervisor Startup\nPackages")
                     contents))))
        (emacs-hypervisor-reset)
        (setq emacs-hypervisor--running-unit-name "personal-ui")
        (setq emacs-hypervisor--unit-events
              '((:kind :attempt :name "personal-ui" :time 101.0)))
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote "Hypervisor Startup\nConfig Units")
                     contents))
            (should-not (string-match-p
                         (regexp-quote "Running personal-ui")
                         contents))))
        (emacs-hypervisor-reset)
        (setq emacs-hypervisor--completed t)
        (setq emacs-hypervisor--state :failed)
        (setq emacs-hypervisor--shutdown-reason :config-load-failed)
        (setq emacs-hypervisor--session-started-at 100.0)
        (setq emacs-hypervisor--session-finished-at 103.25)
        (setq emacs-hypervisor--last-error-message
              "config load failed: (error \"bad key\")")
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote "Hypervisor Startup\nFailed after 3.25s")
                     contents))
            (should-not (string-match-p
                         (regexp-quote "Failed: config load failed")
                        contents)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-banner-shows-finished-elapsed-time ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--completed t)
  (setq emacs-hypervisor--state :completed)
  (setq emacs-hypervisor--session-started-at 100.0)
  (setq emacs-hypervisor--session-finished-at 102.5)
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (should (string-match-p
                   (regexp-quote "Hypervisor Startup\nFinished in 2.50s")
                   (buffer-string)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-banner-keeps-unit-stage-between-units ()
  (unwind-protect
      (progn
        (emacs-hypervisor-reset)
        (setq emacs-hypervisor--unit-events
              '((:kind :attempt :name "unit-a" :time 101.0)))
        (setq emacs-hypervisor--running-unit-name "unit-a")
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (should (string-match-p
                   (regexp-quote "Hypervisor Startup\nConfig Units")
                   (buffer-string))))
        (setq emacs-hypervisor--unit-events
              '((:kind :success :name "unit-a" :time 102.0)
                (:kind :attempt :name "unit-a" :time 101.0)))
        (setq emacs-hypervisor--running-unit-name nil)
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote "Hypervisor Startup\nConfig Units")
                     contents))
            (should-not (string-match-p
                         (regexp-quote "Running unit-a")
                         contents)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-render-skips-unchanged-buffer ()
  (emacs-hypervisor-reset)
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((tick (buffer-chars-modified-tick)))
            (emacs-hypervisor--render-report-buffer)
            (should (= tick (buffer-chars-modified-tick))))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-packages-section-renders-rolling-window ()
  (let ((emacs-hypervisor-report-package-window-size 3))
    (emacs-hypervisor-reset)
    (setq emacs-hypervisor--session-started-at 100.0)
    (setq emacs-hypervisor--plan-messages
          '((:plan :phase :packages
                   :items ((:name "pkg-a")
                           (:name "pkg-b")
                           (:name "pkg-c")
                           (:name "pkg-d")
                           (:name "pkg-e")))))
    (setq emacs-hypervisor--report-messages
          '((:report :stage :planned :phase :packages
                     :items ((:name "pkg-a" :status :ok :reason :ready)
                             (:name "pkg-b" :status :ok :reason :ready)
                             (:name "pkg-c" :status :ok :reason :ready)
                             (:name "pkg-d" :status :ok :reason :ready)
                             (:name "pkg-e" :status :ok :reason :ready)))))
    (setq emacs-hypervisor--package-events
          '((:kind :installed :name "pkg-d" :time 104.0)
            (:kind :installed :name "pkg-c" :time 103.0)
            (:kind :installed :name "pkg-b" :time 102.0)
            (:kind :installed :name "pkg-a" :time 101.0)))
    (unwind-protect
        (progn
          (emacs-hypervisor--render-report-buffer)
          (with-current-buffer (emacs-hypervisor-report-buffer)
            (let ((contents (buffer-string)))
              (should (string-match-p (regexp-quote "Status     Planned")
                                      contents))
              (should (string-match-p
                       (regexp-quote
                        "Hypervisor Startup\nPackages")
                       contents))
              (should (string-match-p
                       (regexp-quote
                        "Progress   4 installed, 1 pending, 0 failed, 0 skipped")
                       contents))
              (should-not (string-match-p (regexp-quote "ready,")
                                          contents))
              (should (string-match-p (regexp-quote "[x] pkg-c")
                                      contents))
              (should (string-match-p (regexp-quote "[x] pkg-d")
                                      contents))
              (should (string-match-p (regexp-quote "[ ] pkg-e")
                                      contents))
              (should-not (string-match-p (regexp-quote "pkg-a")
                                          contents))
              (should-not (string-match-p (regexp-quote "pkg-b")
                                          contents)))))
      (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer)))))

(ert-deftest emacs-hypervisor-report-packages-section-shows-empty-plan-as-installed ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--plan-messages
        '((:plan :phase :packages :items nil)))
  (setq emacs-hypervisor--report-messages
        '((:report :stage :planned :phase :packages
                   :items ((:name "pkg-a" :status :ok :reason :installed)
                           (:name "pkg-b" :status :ok :reason :installed)))))
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p
                     (regexp-quote
                      "Hypervisor Startup\nPreparing")
                     contents))
            (should (string-match-p
                     (regexp-quote "Progress   All packages already installed")
                     contents))
            (should-not (string-match-p (regexp-quote "ready,")
                                        contents))
            (should-not (string-match-p (regexp-quote "[ ] pkg-a")
                                        contents)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-report-packages-section-shows-finished-status ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--plan-messages
        '((:plan :phase :packages
                 :items ((:name "core-pkg")))))
  (setq emacs-hypervisor--report-messages
        '((:report :stage :planned :phase :packages
                   :items ((:name "core-pkg" :status :ok :reason :ready)))))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :package
    '(:phase :packages :kind :installed :name "core-pkg")))
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :package
    '(:phase :packages :kind :finished :reason "completed")))
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (let ((contents (buffer-string)))
            (should (string-match-p (regexp-quote "Status     Completed")
                                    contents))
            (should (string-match-p
                     (regexp-quote
                      "Hypervisor Startup\nPackages")
                     contents))
            (should (string-match-p
                     (regexp-quote
                      "Progress   1 installed, 0 pending, 0 failed, 0 skipped")
                     contents))
            (should-not (string-match-p (regexp-quote "Status     Planned")
                                        contents))
            (should (string-match-p (regexp-quote "[x] core-pkg")
                                    contents)))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-dispatch-rpc-event-records-failed-shutdown ()
  (let (notified)
    (emacs-hypervisor-reset)
    (setq emacs-hypervisor-process-sentinel-function
          (lambda (_proc event)
            (push event notified)))
    (emacs-hypervisor--dispatch
     (emacs-hypervisor-test--event
      :log
      '(:level :error
               :message "config load failed: (error \"bad key\")\nbacktrace...")))
    (emacs-hypervisor--dispatch
     (emacs-hypervisor-test--event
      :shutdown
      '(:reason :config-load-failed)))
    (should (eq emacs-hypervisor--shutdown-reason :config-load-failed))
    (should emacs-hypervisor--completed)
    (should (eq emacs-hypervisor--state :failed))
    (should (equal notified '(":config-load-failed\n")))
    (should (equal emacs-hypervisor--last-error-message
                   "config load failed: (error \"bad key\")\nbacktrace..."))
    (should (equal (emacs-hypervisor-failure-summary)
                   "config load failed: (error \"bad key\")"))
    (emacs-hypervisor-record-startup-warning
     :bootstrap-hash
     "generated init.el is stale")
    (unwind-protect
        (progn
          (emacs-hypervisor--render-report-buffer)
          (with-current-buffer (emacs-hypervisor-report-buffer)
            (let ((contents (buffer-string)))
              (should (string-match-p "Warnings" contents))
              (should (string-match-p "generated init.el is stale" contents))
              (should (string-match-p "Problems" contents))
              (should (string-match-p "startup" contents))
              (should (string-match-p "config load failed" contents)))))
      (kill-buffer emacs-hypervisor--report-buffer-name))))

(ert-deftest emacs-hypervisor-session-ready-marks-ready-without-completing ()
  (emacs-hypervisor-reset)
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :session-ready
    '(:reason :startup-complete :status :ready)))
  (should emacs-hypervisor--ready)
  (should (eq emacs-hypervisor--state :completed))
  (should-not emacs-hypervisor--completed)
  (should (eq (emacs-hypervisor-readiness) 'ready))
  ;; The live-but-ready session must not block local config reloads.
  (cl-letf (((symbol-function 'processp) (lambda (_process) t))
            ((symbol-function 'process-live-p) (lambda (_process) t)))
    (let ((emacs-hypervisor--process :fake-process))
      (should-not (emacs-hypervisor-session-active-p)))))

(ert-deftest emacs-hypervisor-session-ready-then-process-death-is-failed ()
  (emacs-hypervisor-reset)
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :session-ready
    '(:reason :startup-complete :status :ready)))
  (should (eq (emacs-hypervisor-readiness) 'ready))
  (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil)))
    (emacs-hypervisor--sentinel :fake-process "exited abnormally\n"))
  (should (eq emacs-hypervisor--state :failed))
  (should (eq emacs-hypervisor--shutdown-reason :process-exited))
  (should (eq (emacs-hypervisor-readiness) 'failed)))

(ert-deftest emacs-hypervisor-shutdown-then-process-death-stays-completed ()
  (emacs-hypervisor-reset)
  (emacs-hypervisor--dispatch
   (emacs-hypervisor-test--event
    :shutdown
    '(:reason :hypervisor-session-complete)))
  (should emacs-hypervisor--completed)
  (should (eq emacs-hypervisor--state :completed))
  (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil)))
    (emacs-hypervisor--sentinel :fake-process "finished\n"))
  (should (eq emacs-hypervisor--state :completed))
  (should (eq emacs-hypervisor--shutdown-reason :hypervisor-session-complete))
  (should (eq (emacs-hypervisor-readiness) 'ready)))

(ert-deftest emacs-hypervisor-report-session-finished-displays-initial-buffer-when-report-hidden ()
  (let ((emacs-hypervisor-show-report-on-startup nil)
        (emacs-hypervisor-display-initial-buffer-on-finish t)
        (emacs-hypervisor--state :completed)
        (noninteractive nil)
        (initial-buffer-choice
         (lambda () (get-buffer-create "*hypervisor-test-dashboard*")))
        opened-buffer
        report-opened)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-opened t)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _args)
                 (setq opened-buffer buffer))))
      (unwind-protect
          (progn
            (emacs-hypervisor-report-session-finished)
            (should-not report-opened)
            (should (bufferp opened-buffer))
            (should (equal (buffer-name opened-buffer)
                           "*hypervisor-test-dashboard*")))
        (when-let ((buffer (get-buffer "*hypervisor-test-dashboard*")))
          (kill-buffer buffer))
        (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest emacs-hypervisor-report-package-begin-opens-report-on-startup ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor--report-startup-opened nil)
        (noninteractive nil)
        report-opened)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-opened t))))
      (emacs-hypervisor-report-note-package-event :begin)
      (should report-opened))))

(ert-deftest emacs-hypervisor-report-session-finished-skips-initial-buffer-on-failure ()
  (let ((emacs-hypervisor-show-report-on-startup nil)
        (emacs-hypervisor-display-initial-buffer-on-finish t)
        (emacs-hypervisor--state :failed)
        (noninteractive nil)
        (initial-buffer-choice
         (lambda () (get-buffer-create "*hypervisor-test-dashboard*")))
        opened-buffer)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _args)
                 (setq opened-buffer buffer))))
      (unwind-protect
          (progn
            (emacs-hypervisor-report-session-finished)
            (should-not opened-buffer))
        (when-let ((buffer (get-buffer "*hypervisor-test-dashboard*")))
          (kill-buffer buffer))
        (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest emacs-hypervisor-report-note-unit-event-opens-report-on-failure ()
  (let ((emacs-hypervisor-show-report-on-startup nil)
        (noninteractive nil)
        report-opened)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-opened t))))
      (emacs-hypervisor-report-note-unit-event :failed "bad-unit" "boom")
      (should report-opened))))

(ert-deftest emacs-hypervisor-runtime-run-package-installs-one-without-phase-bracket ()
  "`run-package' emits only the per-package :installed event, not :begin/:finished."
  (let (sent)
    (setq emacs-hypervisor-installed-packages nil)
    (setq emacs-hypervisor-execution-events nil)
    (setq emacs-hypervisor-packages '((:name "core-pkg")))
    (cl-letf (((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload) (push (list topic payload) sent)))
              ((symbol-function 'emacs-hypervisor-bridge-install-batch)
               (lambda (entries on-installed _on-failed)
                 (dolist (entry entries)
                   (funcall on-installed (plist-get entry :name)))
                 :done)))
      (should (equal (emacs-hypervisor-runtime-run-package "core-pkg") "core-pkg")))
    (setq sent (nreverse sent))
    (should (equal emacs-hypervisor-installed-packages '("core-pkg")))
    ;; Only :installed -- the host brackets the loop with :begin/:finished.
    (should (equal (mapcar (lambda (e) (plist-get (cadr e) :kind)) sent)
                   '(:installed)))))

(ert-deftest emacs-hypervisor-runtime-run-package-signals-on-failure ()
  "`run-package' emits :failed and re-signals so the host derives the report."
  (let (sent)
    (setq emacs-hypervisor-installed-packages nil)
    (setq emacs-hypervisor-execution-events nil)
    (setq emacs-hypervisor-packages '((:name "ui-pkg")))
    (cl-letf (((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload) (push (list topic payload) sent)))
              ((symbol-function 'emacs-hypervisor-bridge-install-batch)
               (lambda (_entries _on-installed on-failed)
                 (funcall on-failed "ui-pkg" "clone error")
                 :done)))
      (should-error (emacs-hypervisor-runtime-run-package "ui-pkg") :type 'error))
    (setq sent (nreverse sent))
    (should (equal (mapcar (lambda (e) (plist-get (cadr e) :kind)) sent)
                   '(:failed)))
    (should (equal (plist-get (cadr (car sent)) :reason) "clone error"))))

(ert-deftest emacs-hypervisor-bridge-build-url-honors-host-and-local ()
  (should (equal (emacs-hypervisor-bridge--build-url
                  '(:name "magit" :repo "magit/magit"))
                 "https://github.com/magit/magit"))
  (should (equal (emacs-hypervisor-bridge--build-url
                  '(:name "x" :repo "user/x" :host "gitlab"))
                 "https://gitlab.com/user/x"))
  (should (equal (emacs-hypervisor-bridge--build-url
                  '(:name "x" :repo "https://example.com/user/x.git"))
                 "https://example.com/user/x.git"))
  (should (string-prefix-p
           "file://"
           (emacs-hypervisor-bridge--build-url
            '(:name "x" :local "/tmp/x"))))
  (should-not (emacs-hypervisor-bridge--build-url
               '(:name "x"))))

(ert-deftest emacs-hypervisor-bridge-activate-initializes-installed-packages-only ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (package-user-dir (expand-file-name "wrong-packages/" home-dir))
         (package--initialized nil)
         (package-archive-contents nil)
         (emacs-hypervisor-bridge-ready nil)
         (emacs-hypervisor-bridge-activated nil)
         initialized
         refreshed)
    (unwind-protect
        (cl-letf (((symbol-function 'package-initialize)
                   (lambda (&optional _no-activate)
                     (setq initialized t)
                     (setq package--initialized t)))
                  ((symbol-function 'package-refresh-contents)
                   (lambda ()
                     (setq refreshed t))))
          (should (eq (emacs-hypervisor-bridge-activate) :activated))
          (should initialized)
          (should-not refreshed)
          (should package--initialized)
          (should emacs-hypervisor-bridge-activated)
          (should-not emacs-hypervisor-bridge-ready)
          (should (equal package-user-dir
                         (expand-file-name "hypervisor/packages/" home-dir)))
          (should (file-directory-p package-user-dir)))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-installed-vc-entry-activates-lisp-dir ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (package-user-dir (expand-file-name "hypervisor/packages/" home-dir))
         (package-vc-selected-packages nil)
         (package-alist nil)
         (entry '(:name "ghostel"
                  :repo "dakra/ghostel"
                  :branch "main"
                  :lisp-dir "lisp"))
         (load-path load-path)
         (lisp-dir (file-name-as-directory
                    (expand-file-name
                     "hypervisor/packages/ghostel/lisp"
                     home-dir))))
    (unwind-protect
        (progn
          (make-directory lisp-dir t)
          (should-not (emacs-hypervisor-bridge--installed-p entry))
          (cl-letf (((symbol-function 'package-installed-p)
                     (lambda (package &optional _min-version)
                       (eq package 'ghostel))))
            (should (emacs-hypervisor-bridge--installed-p entry))
            (emacs-hypervisor-bridge--note-present entry)
            (should (equal (alist-get 'ghostel package-vc-selected-packages)
                           '(:url "https://github.com/dakra/ghostel"
                             :branch "main"
                             :lisp-dir "lisp")))
            (should (member lisp-dir load-path))))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-archive-install-activates-current-session ()
  (let ((installed nil)
        (noted-entry nil)
        (entry '(:name "archive-addon")))
    (cl-letf (((symbol-function 'package-installed-p)
               (lambda (_package &optional _min-version) installed))
              ((symbol-function 'package-install)
               (lambda (_package) (setq installed t)))
              ((symbol-function 'emacs-hypervisor-bridge--note-present)
               (lambda (entry) (setq noted-entry entry))))
      (emacs-hypervisor-bridge--archive-install entry)
      (should installed)
      (should (equal noted-entry entry)))))

(ert-deftest emacs-hypervisor-bridge-archive-install-retries-after-refresh ()
  "When `package-install' fails, refresh archives once and retry."
  (let ((emacs-hypervisor-bridge--archive-refreshed-on-error nil)
        (attempt 0)
        (refreshed nil)
        (entry '(:name "stale-pkg")))
    (cl-letf (((symbol-function 'package-installed-p)
               (lambda (_package &optional _min-version) nil))
              ((symbol-function 'package-install)
               (lambda (_package)
                 (cl-incf attempt)
                 (when (= attempt 1)
                   (error "Not found"))))
              ((symbol-function 'package-refresh-contents)
               (lambda () (setq refreshed t)))
              ((symbol-function 'emacs-hypervisor-bridge--note-present)
               #'ignore)
              ((symbol-function 'emacs-hypervisor-bridge--record-archive-lock)
               #'ignore))
      (emacs-hypervisor-bridge--archive-install entry)
      (should refreshed)
      (should (= attempt 2))
      (should emacs-hypervisor-bridge--archive-refreshed-on-error))))

(ert-deftest emacs-hypervisor-bridge-archive-install-retry-only-once ()
  "A second archive failure re-signals instead of refreshing again."
  (let ((emacs-hypervisor-bridge--archive-refreshed-on-error nil)
        (attempt 0)
        (refresh-count 0)
        (entry '(:name "gone-pkg")))
    (cl-letf (((symbol-function 'package-installed-p)
               (lambda (_package &optional _min-version) nil))
              ((symbol-function 'package-install)
               (lambda (_package)
                 (cl-incf attempt)
                 (error "Not found")))
              ((symbol-function 'package-refresh-contents)
               (lambda () (cl-incf refresh-count)))
              ((symbol-function 'emacs-hypervisor-bridge--note-present)
               #'ignore)
              ((symbol-function 'emacs-hypervisor-bridge--record-archive-lock)
               #'ignore))
      (should-error (emacs-hypervisor-bridge--archive-install entry))
      (should (= refresh-count 1))
      (should (= attempt 2)))))

(ert-deftest emacs-hypervisor-bridge-uses-namespaced-source-root ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (entry '(:name "vc-tool" :repo "example/vc-tool")))
    (unwind-protect
        (should (equal
                 (emacs-hypervisor-bridge--clone-dir entry)
                 (expand-file-name "hypervisor/sources/vc-tool" home-dir)))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-install-batch-preserves-plan-order ()
  (let* ((entries
          '((:name "archive-core")
            (:name "vc-tool" :repo "example/vc-tool")
            (:name "archive-addon" :deps ("vc-tool" "archive-core"))))
         operations
         installed)
    (cl-letf (((symbol-function 'emacs-hypervisor-bridge-init)
               (lambda () :ready))
              ((symbol-function 'emacs-hypervisor-bridge--installed-p)
               (lambda (entry)
                 (member (plist-get entry :name) installed)))
              ((symbol-function 'emacs-hypervisor-bridge--clone-present-p)
               (lambda (_entry) nil))
              ((symbol-function 'emacs-hypervisor-bridge--pump-clones)
               (lambda (vc-entries on-each)
                 (dolist (entry (reverse vc-entries))
                   (funcall on-each entry :ok))))
              ((symbol-function 'emacs-hypervisor-bridge--adopt)
               (lambda (entry)
                 (push (list :adopt (plist-get entry :name)) operations)
                 (push (plist-get entry :name) installed)))
              ((symbol-function 'emacs-hypervisor-bridge--archive-install)
               (lambda (entry)
                 (push (list :archive (plist-get entry :name)) operations)
                 (push (plist-get entry :name) installed)))
              ((symbol-function 'emacs-hypervisor-bridge--note-present)
               (lambda (_entry) nil)))
      (emacs-hypervisor-bridge-install-batch
       entries
       (lambda (name) (push (list :installed name) operations))
       (lambda (name reason) (push (list :failed name reason) operations)))
      (should
       (equal (nreverse operations)
              '((:archive "archive-core")
                (:installed "archive-core")
                (:adopt "vc-tool")
                (:installed "vc-tool")
                (:archive "archive-addon")
                (:installed "archive-addon")))))))

(ert-deftest emacs-hypervisor-bridge-adopt-replaces-incomplete-package-symlink ()
  (let* ((entry '(:name "vc-tool" :repo "example/vc-tool"))
         (home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-adopt-test" t)))
         (user-emacs-directory home-dir)
         (package-user-dir (expand-file-name "hypervisor/packages/" home-dir))
         (clone-dir (expand-file-name "hypervisor/sources/vc-tool" home-dir))
         (pkg-dir (expand-file-name "hypervisor/packages/vc-tool" home-dir))
         installed-from-checkout)
    (unwind-protect
        (progn
          (make-directory clone-dir t)
          (make-directory package-user-dir t)
          (make-symbolic-link clone-dir pkg-dir)
          (cl-letf (((symbol-function 'package-installed-p)
                     (lambda (_package &optional _min-version) nil))
                    ((symbol-function 'emacs-hypervisor-bridge--prepare-checkout)
                     (lambda (_entry) :prepared))
                    ((symbol-function 'package-vc-install-from-checkout)
                     (lambda (dir name)
                       (should (equal dir clone-dir))
                       (should (equal name "vc-tool"))
                       (should-not (file-symlink-p pkg-dir))
                       (should-not (file-exists-p pkg-dir))
                       (setq installed-from-checkout t)))
                    ((symbol-function 'emacs-hypervisor-bridge--record-vc-lock)
                     (lambda (_entry) "rev")))
            (emacs-hypervisor-bridge--adopt entry)
            (should installed-from-checkout)))
      (when (file-exists-p home-dir)
        (delete-directory home-dir t)))))

(ert-deftest emacs-hypervisor-bridge-vc-entry-p-detects-archive-vs-vc ()
  (should     (emacs-hypervisor-bridge--vc-entry-p '(:name "magit" :repo "magit/magit")))
  (should     (emacs-hypervisor-bridge--vc-entry-p '(:name "x" :local "/tmp/x")))
  (should-not (emacs-hypervisor-bridge--vc-entry-p '(:name "archive-only"))))

(ert-deftest emacs-hypervisor-bridge-vc-spec-preserves-ref ()
  (should (equal
           (emacs-hypervisor-bridge--vc-spec
            '(:name "marginalia"
              :repo "minad/marginalia"
              :ref "4a0628dfdf944a5d307d31d2a514825cc5386986"))
           '(:url "https://github.com/minad/marginalia"
             :rev "4a0628dfdf944a5d307d31d2a514825cc5386986"))))

(ert-deftest emacs-hypervisor-bridge-ref-clones-are-not-shallow ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (entry '(:name "marginalia"
                  :repo "minad/marginalia"
                  :ref "4a0628dfdf944a5d307d31d2a514825cc5386986")))
    (unwind-protect
        (let ((command (emacs-hypervisor-bridge--clone-command entry)))
          (should-not (member "--depth" command))
          (should-not (member "--no-single-branch" command)))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-submodules-clone-recurses ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (entry '(:name "treesit-grammars"
                  :repo "example/treesit-grammars"
                  :submodules t)))
    (unwind-protect
        (let ((command (emacs-hypervisor-bridge--clone-command entry)))
          (should (member "--recurse-submodules" command)))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-no-submodules-no-recurse ()
  (let* ((home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-home" t)))
         (user-emacs-directory home-dir)
         (entry '(:name "vertico" :repo "minad/vertico")))
    (unwind-protect
        (let ((command (emacs-hypervisor-bridge--clone-command entry)))
          (should-not (member "--recurse-submodules" command)))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-rebuild-drops-cache-and-reinstalls ()
  (let* ((entry '(:name "vc-tool" :repo "example/vc-tool"))
         (home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-rebuild-test" t)))
         (user-emacs-directory home-dir)
         (package-user-dir (expand-file-name "hypervisor/packages/" home-dir))
         (package-alist nil)
         (package-activated-list nil)
         (package-vc-selected-packages nil)
         deleted-dirs
         reinstalled-batch)
    (unwind-protect
        (let ((clone-dir (expand-file-name "hypervisor/sources/vc-tool" home-dir))
              (pkg-dir (expand-file-name "hypervisor/packages/vc-tool" home-dir)))
          (make-directory clone-dir t)
          (make-directory pkg-dir t)
          (push (list 'vc-tool) package-alist)
          (push 'vc-tool package-activated-list)
          (setf (alist-get 'vc-tool package-vc-selected-packages) '(:url "example/vc-tool"))
          (cl-letf (((symbol-function 'delete-directory)
                     (lambda (dir &optional _recursive _trash)
                       (push dir deleted-dirs)))
                    ((symbol-function 'emacs-hypervisor-bridge-install-batch)
                     (lambda (entries _on-installed _on-failed)
                       (setq reinstalled-batch entries)
                       :done)))
            (emacs-hypervisor-bridge-rebuild entry nil nil)
            (should (member clone-dir deleted-dirs))
            (should (member pkg-dir deleted-dirs))
            (should-not (assq 'vc-tool package-alist))
            (should-not (member 'vc-tool package-activated-list))
            (should-not (assq 'vc-tool package-vc-selected-packages))
            (should (equal reinstalled-batch (list entry)))))
      (delete-directory home-dir t))))

(ert-deftest emacs-hypervisor-bridge-purge-removes-package-symlink-after-clone-delete ()
  (let* ((entry '(:name "vc-tool" :repo "example/vc-tool"))
         (home-dir (file-name-as-directory
                    (make-temp-file "emacs-hypervisor-bridge-symlink-test" t)))
         (user-emacs-directory home-dir)
         (package-user-dir (expand-file-name "hypervisor/packages/" home-dir))
         (package-alist nil)
         (package-activated-list nil)
         (package-vc-selected-packages nil)
         (clone-dir (expand-file-name "hypervisor/sources/vc-tool" home-dir))
         (pkg-dir (expand-file-name "hypervisor/packages/vc-tool" home-dir)))
    (unwind-protect
        (progn
          (make-directory clone-dir t)
          (make-directory package-user-dir t)
          (make-symbolic-link clone-dir pkg-dir)
          (emacs-hypervisor-bridge--purge-package entry)
          (should-not (file-exists-p clone-dir))
          (should-not (file-symlink-p pkg-dir))
          (should-not (file-exists-p pkg-dir)))
      (when (file-exists-p home-dir)
        (delete-directory home-dir t)))))

(ert-deftest emacs-hypervisor-runtime-rebuild-package-triggers-rebuild ()
  (let* ((entry '(:name "vc-tool"))
         (emacs-hypervisor-packages (list entry))
         (emacs-hypervisor-installed-packages nil)
         (emacs-hypervisor-execution-events nil)
         rebuild-called
         installed-called
         sent-events)
    (cl-letf (((symbol-function 'emacs-hypervisor-bridge-rebuild)
               (lambda (ent on-installed _on-failed)
                 (setq rebuild-called ent)
                 (funcall on-installed "vc-tool")))
              ((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload)
                 (push (list topic payload) sent-events))))
      (should (equal (emacs-hypervisor-runtime-rebuild-package "vc-tool") "vc-tool"))
      (should (equal rebuild-called entry))
      (should (equal emacs-hypervisor-installed-packages '("vc-tool")))
      (should (equal (car (car sent-events)) :package))
      (should (equal (plist-get (cadr (car sent-events)) :kind) :installed)))))


(require 'emacs-hypervisor-package-lock)

(defmacro emacs-hypervisor-test--with-temp-lock (&rest body)
  "Run BODY with the package lockfile bound to a fresh temp path."
  (declare (indent 0))
  `(let* ((lock-dir (make-temp-file "hypervisor-lock-test" t))
          (emacs-hypervisor-package-lock-file
           (expand-file-name "hypervisor.lock" lock-dir)))
     (unwind-protect
         (progn ,@body)
       (delete-directory lock-dir t))))

(ert-deftest emacs-hypervisor-session-base-defines-and-resets-session-vars ()
  (should (featurep 'emacs-hypervisor-session-base))
  (should (boundp 'emacs-hypervisor-execution-events))
  (should (boundp 'emacs-hypervisor-installed-packages))
  ;; The module is (re)evaluated at every session start; loading it again
  ;; must reset the session accumulators.
  (let ((emacs-hypervisor-execution-events '(:stale-event))
        (emacs-hypervisor-installed-packages '("stale-package")))
    (load "emacs-hypervisor-session-base" nil t)
    (should (null emacs-hypervisor-execution-events))
    (should (null emacs-hypervisor-installed-packages))))

(ert-deftest emacs-hypervisor-bridge-adopt-enforces-locked-revision ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "vc-tool" :kind :vc :rev "locked-rev"))
    (let ((entry '(:name "vc-tool" :repo "example/vc-tool"))
          operations)
      (cl-letf (((symbol-function 'emacs-hypervisor-bridge-init)
                 (lambda () :ready))
                ((symbol-function 'emacs-hypervisor-bridge--installed-p)
                 (lambda (_entry) nil))
                ((symbol-function 'package-installed-p)
                 (lambda (_package &optional _min-version) nil))
                ((symbol-function 'emacs-hypervisor-bridge--clone-present-p)
                 (lambda (_entry) t))
                ((symbol-function 'emacs-hypervisor-bridge--checkout-ref)
                 (lambda (checkout-entry)
                   (push (list :checkout
                               (emacs-hypervisor-bridge--resolved-rev
                                checkout-entry))
                         operations)))
                ((symbol-function 'emacs-hypervisor-bridge--prepare-checkout)
                 (lambda (_entry) (push '(:prepare) operations)))
                ((symbol-function 'emacs-hypervisor-bridge--delete-cache-path)
                 (lambda (_path) nil))
                ((symbol-function 'package-vc-install-from-checkout)
                 (lambda (_dir _name) (push '(:install) operations)))
                ((symbol-function 'emacs-hypervisor-bridge--record-vc-lock)
                 (lambda (_entry) "locked-rev"))
                ((symbol-function 'emacs-hypervisor-bridge--note-present)
                 (lambda (_entry) nil)))
        (emacs-hypervisor-bridge-install-batch
         (list entry)
         (lambda (_name))
         (lambda (name reason)
           (ert-fail (format "install failed for %s: %s" name reason))))
        ;; A pre-existing clone is adopted at the locked revision, before
        ;; the build step runs.
        (should (equal (nreverse operations)
                       '((:checkout "locked-rev")
                         (:prepare)
                         (:install))))))))

(ert-deftest emacs-hypervisor-package-lock-rejects-mismatched-schema ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "zeta" :kind :vc :rev "aaa"))
    (should (emacs-hypervisor-package-lock-read))
    ;; Rewrite the lockfile with a bumped schema version.
    (with-temp-file (emacs-hypervisor-package-lock--file)
      (insert (format "%S"
                      (list :schema-version
                            (1+ emacs-hypervisor-package-lock-schema-version)
                            :entries '((:name "zeta" :kind :vc :rev "aaa"))
                            :future-field :do-not-destroy))))
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _args) (push msg warnings))))
        (should (null (emacs-hypervisor-package-lock-read)))
        (should (null (emacs-hypervisor-package-lock-entry "zeta")))
        (should warnings)
        (should (string-match-p "schema version" (car warnings)))))))

(ert-deftest emacs-hypervisor-package-lock-roundtrip-is-sorted ()
  (emacs-hypervisor-test--with-temp-lock
    (should (null (emacs-hypervisor-package-lock-read)))
    (emacs-hypervisor-package-lock-put
     '(:name "zeta" :kind :vc :rev "aaa"))
    (emacs-hypervisor-package-lock-put
     '(:name "alpha" :kind :archive :version (1 0)))
    (let ((entries (emacs-hypervisor-package-lock-entries)))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) entries)
                     '("alpha" "zeta"))))
    ;; Upsert replaces by name rather than duplicating.
    (emacs-hypervisor-package-lock-put
     '(:name "zeta" :kind :vc :rev "bbb"))
    (should (equal (plist-get (emacs-hypervisor-package-lock-entry "zeta") :rev)
                   "bbb"))
    (should (= (length (emacs-hypervisor-package-lock-entries)) 2))
    (emacs-hypervisor-package-lock-remove "alpha")
    (should (null (emacs-hypervisor-package-lock-entry "alpha")))))

(ert-deftest emacs-hypervisor-package-lock-resolution-precedence ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "magit" :kind :vc :rev "locked-rev"))
    ;; Declared :ref wins over the lock.
    (let ((pinned '(:name "magit" :repo "magit/magit" :ref "declared-rev")))
      (should (equal (emacs-hypervisor-bridge--resolved-rev pinned)
                     "declared-rev"))
      (should (eq (emacs-hypervisor-bridge--locked-how pinned) :pinned)))
    ;; Without a declared pin the lock revision drives resolution.
    (let ((unpinned '(:name "magit" :repo "magit/magit")))
      (should (equal (emacs-hypervisor-bridge--resolved-rev unpinned)
                     "locked-rev"))
      (should (eq (emacs-hypervisor-bridge--locked-how unpinned) :hit))
      ;; A locked revision forces the non-shallow clone shape.
      (should-not (member "--depth"
                          (emacs-hypervisor-bridge--clone-command unpinned)))
      ;; Upgrades ignore the lock.
      (let ((emacs-hypervisor-bridge-ignore-lock t))
        (should (null (emacs-hypervisor-bridge--resolved-rev unpinned)))
        (should (eq (emacs-hypervisor-bridge--locked-how unpinned) :miss))))
    ;; No lock entry at all resolves to the branch/default HEAD shape.
    (let ((unknown '(:name "consult" :repo "minad/consult")))
      (should (null (emacs-hypervisor-bridge--resolved-rev unknown)))
      (should (member "--depth"
                      (emacs-hypervisor-bridge--clone-command unknown))))))

(ert-deftest emacs-hypervisor-package-lock-local-entries-never-drive-resolution ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "mytool" :kind :vc :rev "locked-rev"))
    (should (null (emacs-hypervisor-bridge--locked-rev
                   '(:name "mytool" :local "~/projects/mytool"))))
    (should (null (emacs-hypervisor-bridge--locked-rev
                   '(:name "mytool" :repo "~/projects/mytool"))))))

(ert-deftest emacs-hypervisor-upgrade-pinned-package-skips-rebuild ()
  (emacs-hypervisor-test--with-temp-lock
    (let ((entry '(:name "vc-tool" :repo "owner/vc-tool" :tag "v1.0"))
          rebuild-called)
      (cl-letf (((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (&rest _) (setq rebuild-called t))))
        (let ((report (emacs-hypervisor-runtime--upgrade-entry entry)))
          (should (eq (plist-get report :status) :pinned))
          (should-not rebuild-called))))))

(ert-deftest emacs-hypervisor-upgrade-updates-lock-and-reports-rev-delta ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "vc-tool" :kind :vc :rev "old-rev"))
    (let ((entry '(:name "vc-tool" :repo "owner/vc-tool")))
      (cl-letf (((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (ent on-installed _on-failed)
                   ;; The real rebuild records the fresh revision during
                   ;; adopt; simulate that effect.
                   (should (plist-get ent :name))
                   (emacs-hypervisor-package-lock-put
                    '(:name "vc-tool" :kind :vc :rev "new-rev"))
                   (funcall on-installed "vc-tool"))))
        (let ((report (emacs-hypervisor-runtime--upgrade-entry entry)))
          (should (eq (plist-get report :status) :ok))
          (should (equal (plist-get report :previous-rev) "old-rev"))
          (should (equal (plist-get report :current-rev) "new-rev")))))))

(ert-deftest emacs-hypervisor-upgrade-reports-archive-version-delta ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "archive-tool" :kind :archive :version (1 0)))
    (let ((entry '(:name "archive-tool")))
      (cl-letf (((symbol-function 'package-refresh-contents)
                 (lambda (&rest _args) t))
                ((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (_entry on-installed _on-failed)
                   (emacs-hypervisor-package-lock-put
                    '(:name "archive-tool" :kind :archive :version (2 0)))
                   (funcall on-installed "archive-tool"))))
        (let ((report (emacs-hypervisor-runtime--upgrade-entry-with-refresh
                       entry)))
          (should (eq (plist-get report :status) :ok))
          (should (equal (plist-get report :previous-rev) '(1 0)))
          (should (equal (plist-get report :current-rev) '(2 0))))))))

(ert-deftest emacs-hypervisor-upgrade-all-refreshes-archive-index-once ()
  (emacs-hypervisor-test--with-temp-lock
    (let ((refresh-count 0)
          rebuilt)
      (cl-letf (((symbol-function 'emacs-hypervisor-export-packages)
                 (lambda () '((:name "archive-a") (:name "archive-b"))))
                ((symbol-function 'package-refresh-contents)
                 (lambda (&rest _args) (cl-incf refresh-count)))
                ((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (entry on-installed _on-failed)
                   (push (plist-get entry :name) rebuilt)
                   (funcall on-installed (plist-get entry :name)))))
        (emacs-hypervisor-upgrade-all-packages)
        (should (= refresh-count 1))
        (should (equal (nreverse rebuilt) '("archive-a" "archive-b")))))))

(ert-deftest emacs-hypervisor-upgrade-all-survives-archive-refresh-failure ()
  (emacs-hypervisor-test--with-temp-lock
    (emacs-hypervisor-package-lock-put
     '(:name "vc-tool" :kind :vc :rev "old-rev"))
    (let (rebuilt)
      (cl-letf (((symbol-function 'emacs-hypervisor-export-packages)
                 (lambda () '((:name "archive-tool")
                              (:name "vc-tool" :repo "owner/vc-tool"))))
                ((symbol-function 'package-refresh-contents)
                 (lambda (&rest _args) (error "network down")))
                ((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (entry on-installed _on-failed)
                   (push (plist-get entry :name) rebuilt)
                   (when (equal (plist-get entry :name) "vc-tool")
                     (emacs-hypervisor-package-lock-put
                      '(:name "vc-tool" :kind :vc :rev "new-rev")))
                   (funcall on-installed (plist-get entry :name)))))
        (let* ((reports (emacs-hypervisor-upgrade-all-packages))
               (archive-report
                (cl-find "archive-tool" reports
                         :key (lambda (r) (plist-get r :name)) :test #'equal))
               (vc-report
                (cl-find "vc-tool" reports
                         :key (lambda (r) (plist-get r :name)) :test #'equal)))
          ;; The archive entry fails with the network reason, is never
          ;; rebuilt blind, and the VC entry still upgrades.
          (should (eq (plist-get archive-report :status) :failed))
          (should (string-match-p "network down"
                                  (plist-get archive-report :reason)))
          (should (equal rebuilt '("vc-tool")))
          (should (eq (plist-get vc-report :status) :ok))
          (should (equal (plist-get vc-report :current-rev) "new-rev")))))))

(ert-deftest emacs-hypervisor-upgrade-entry-failure-yields-failed-report ()
  (emacs-hypervisor-test--with-temp-lock
    (let ((entry '(:name "vc-tool" :repo "owner/vc-tool")))
      (cl-letf (((symbol-function 'emacs-hypervisor-bridge-rebuild)
                 (lambda (_entry _on-installed _on-failed)
                   (error "purge exploded"))))
        (let ((report (emacs-hypervisor-runtime--upgrade-entry entry)))
          (should (eq (plist-get report :status) :failed))
          (should (string-match-p "purge exploded"
                                  (plist-get report :reason))))))))

(ert-deftest emacs-hypervisor-prune-continues-after-removal-failure ()
  (let ((emacs-hypervisor-packages nil)
        removed
        messages)
    (cl-letf (((symbol-function 'emacs-hypervisor-bridge-orphaned-packages)
               (lambda (_declared) '("bad-orphan" "good-orphan")))
              ((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
              ((symbol-function 'emacs-hypervisor-bridge-remove-package)
               (lambda (name)
                 (if (equal name "bad-orphan")
                     (error "locked file")
                   (push name removed))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (emacs-hypervisor-prune-packages))
    (should (equal removed '("good-orphan")))
    (should (cl-some (lambda (m) (string-match-p "Pruned 1 of 2" m))
                     messages))
    (should (cl-some (lambda (m) (string-match-p "bad-orphan" m))
                     messages))))

(ert-deftest emacs-hypervisor-prune-keep-set-includes-requires-closure ()
  (let* ((temp-home (make-temp-file "hypervisor-prune-test" t))
         (user-emacs-directory (file-name-as-directory temp-home))
         (package-user-dir (expand-file-name "hypervisor/packages" temp-home)))
    (unwind-protect
        (let* ((pkg-dir (lambda (name)
                          (let ((dir (expand-file-name name package-user-dir)))
                            (make-directory dir t)
                            dir)))
               (package-alist
                (list
                 (list 'mypkg (package-desc-create
                               :name 'mypkg :version '(1 0)
                               :reqs '((dep (1 0)))
                               :dir (funcall pkg-dir "mypkg")))
                 (list 'dep (package-desc-create
                             :name 'dep :version '(1 0)
                             :dir (funcall pkg-dir "dep")))
                 (list 'stale (package-desc-create
                               :name 'stale :version '(1 0)
                               :dir (funcall pkg-dir "stale"))))))
          ;; A stale staging clone with no declaration is also an orphan.
          (make-directory
           (expand-file-name "hypervisor/sources/stale-clone" temp-home) t)
          (should (equal (emacs-hypervisor-bridge-orphaned-packages '("mypkg"))
                         '("stale" "stale-clone"))))
      (delete-directory temp-home t))))

(ert-deftest emacs-hypervisor-installed-event-carries-rev-and-locked ()
  (let ((emacs-hypervisor-bridge-last-install-info
         '(("vc-tool" . (:rev "abc123" :locked :hit))))
        (emacs-hypervisor-installed-packages nil)
        (emacs-hypervisor-execution-events nil)
        sent-events)
    (cl-letf (((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload)
                 (push (list topic payload) sent-events))))
      (emacs-hypervisor-runtime-package-installed "vc-tool")
      (let ((payload (cadr (car sent-events))))
        (should (equal (plist-get payload :rev) "abc123"))
        (should (eq (plist-get payload :locked) :hit))))))

(require 'emacs-hypervisor-config-loader)

(ert-deftest emacs-hypervisor-source-map-resolves-org-heading-and-line ()
  (let* ((config-dir (make-temp-file "hypervisor-source-map" t))
         (org-file (expand-file-name "config.org" config-dir)))
    (unwind-protect
        (progn
          (with-temp-file org-file
            (insert "* Editing\n\n"
                    "#+begin_src emacs-lisp\n"
                    "(setq emacs-hypervisor-test-runtime-value 1)\n"
                    "#+end_src\n\n"
                    "* Magit\n\n"
                    "#+begin_src emacs-lisp\n"
                    ";; a comment shifts following lines\n"
                    "(config-unit! magit-source-unit\n"
                    "  :config\n"
                    "  (setq emacs-hypervisor-test-runtime-value 2))\n"
                    "#+end_src\n"))
          (emacs-hypervisor-reset-declarations)
          (emacs-hypervisor--load-with-source-map
           (emacs-hypervisor--tangle-config-org-file org-file))
          (let* ((unit (car (emacs-hypervisor-export-config-units)))
                 (source (plist-get unit :source)))
            (should (equal (plist-get unit :name) "magit-source-unit"))
            (should (equal (plist-get source :file) org-file))
            (should (equal (plist-get source :heading) "Magit"))
            ;; The declaration sits on org line 11: heading 7, blank 8,
            ;; begin_src 9, comment 10, (config-unit! 11.
            (should (equal (plist-get source :line) 11))
            (should (integerp (plist-get source :tangled-line)))))
      (delete-directory config-dir t))))

(ert-deftest emacs-hypervisor-source-map-resolves-plain-config-el-line ()
  (let* ((config-dir (make-temp-file "hypervisor-source-el" t))
         (el-file (expand-file-name "config.el" config-dir)))
    (unwind-protect
        (progn
          (with-temp-file el-file
            (insert ";;; config.el -*- lexical-binding: t; -*-\n\n"
                    "(package! transient)\n"))
          (emacs-hypervisor-reset-declarations)
          (emacs-hypervisor--load-with-source-map el-file)
          (let* ((package (car (emacs-hypervisor-export-packages)))
                 (source (plist-get package :source)))
            (should (equal (plist-get package :name) "transient"))
            (should (equal (plist-get source :file) el-file))
            (should (equal (plist-get source :line) 3))
            (should (null (plist-get source :heading)))))
      (delete-directory config-dir t))))

(ert-deftest emacs-hypervisor-selective-reload-ignores-source-and-index ()
  (let ((previous '(:name "editing" :requires nil :after nil :env nil
                    :executable nil :body (progn t)
                    :source (:file "config.org" :line 4) :index 0))
        (current '(:name "editing" :requires nil :after nil :env nil
                   :executable nil :body (progn t)
                   :source (:file "config.org" :line 90) :index 3)))
    (should (emacs-hypervisor-selective-reload-unit-equal-p previous current))
    ;; A real body change still dirties the unit.
    (should-not
     (emacs-hypervisor-selective-reload-unit-equal-p
      previous
      (plist-put (copy-sequence current) :body '(progn 2 t))))))

(ert-deftest emacs-hypervisor-selective-reload-ignores-embedded-effect-source ()
  (let (previous current changed)
    ;; The same unit declared at different source lines embeds different
    ;; :source provenance into its rewritten effect call.
    (emacs-hypervisor-reset-declarations)
    (let ((emacs-hypervisor--current-source
           '(:file "config.org" :heading "Hooks" :line 4)))
      (eval '(config-unit! hooked-unit
               :config
               (add-hook 'emacs-hypervisor-test-drift-hook #'ignore))
            t))
    (setq previous (emacs-hypervisor-export-config-units))
    (emacs-hypervisor-reset-declarations)
    (let ((emacs-hypervisor--current-source
           '(:file "config.org" :heading "Hooks" :line 90)))
      (eval '(config-unit! hooked-unit
               :config
               (add-hook 'emacs-hypervisor-test-drift-hook #'ignore))
            t))
    (setq current (emacs-hypervisor-export-config-units))
    ;; Sanity: line drift really is baked into the exported bodies.
    (should-not (equal (plist-get (car previous) :body)
                       (plist-get (car current) :body)))
    (should (emacs-hypervisor-selective-reload-unit-equal-p
             (car previous) (car current)))
    (should (equal (mapcar #'emacs-hypervisor-selective-reload-diff-action
                           (emacs-hypervisor-selective-reload-diff-units
                            previous current))
                   '(:unchanged)))
    ;; A genuinely different hook target still dirties the unit.
    (emacs-hypervisor-reset-declarations)
    (let ((emacs-hypervisor--current-source
           '(:file "config.org" :heading "Hooks" :line 90)))
      (eval '(config-unit! hooked-unit
               :config
               (add-hook 'emacs-hypervisor-test-other-drift-hook #'ignore))
            t))
    (setq changed (emacs-hypervisor-export-config-units))
    (should-not (emacs-hypervisor-selective-reload-unit-equal-p
                 (car previous) (car changed)))
    (should (equal (mapcar #'emacs-hypervisor-selective-reload-diff-action
                           (emacs-hypervisor-selective-reload-diff-units
                            previous changed))
                   '(:changed)))))

(ert-deftest emacs-hypervisor-report-refresh-preserves-point-when-unchanged ()
  (emacs-hypervisor-reset)
  (setq emacs-hypervisor--last-progress-message
        '(:progress :phase :planning :step :plans-emitted :done 5 :total 10))
  (unwind-protect
      (progn
        (emacs-hypervisor--render-report-buffer)
        (with-current-buffer (emacs-hypervisor-report-buffer)
          (should (> (point-max) 5))
          (goto-char 5)
          (emacs-hypervisor--render-report-buffer)
          (should (= (point) 5))))
    (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
      (kill-buffer buffer))))

(ert-deftest emacs-hypervisor-reload-format-effect-falls-back-to-source-form ()
  ;; A synthetic record carrying only :source exercises the documented
  ;; fallback path for future effect kinds.
  (let ((hook-effect
         '(:kind :hook
           :source (:form (add-hook 'my-hook #'my-fn)
                    :file "config.org" :line 4)))
        (advice-effect
         '(:kind :advice
           :source (:form (advice-add 'my-fn :around #'my-advice)
                    :file "config.org" :line 9))))
    (should (equal (emacs-hypervisor--reload-format-effect hook-effect)
                   "hook my-hook -> #'my-fn"))
    (should (equal (emacs-hypervisor--reload-format-effect advice-effect)
                   "advice my-fn :around -> #'my-advice"))))

(ert-deftest emacs-hypervisor-effect-record-source-carries-file-and-line ()
  (emacs-hypervisor-reset-declarations)
  (let ((emacs-hypervisor--current-source
         '(:file "config.org" :heading "Hooks" :line 14)))
    (eval '(config-unit! source-hook-unit
             :config
             (add-hook 'emacs-hypervisor-test-source-hook #'ignore))
          t))
  (let* ((entry (car emacs-hypervisor-config-units))
         (registry emacs-hypervisor-effect-registry-current))
    (unwind-protect
        (progn
          (eval (plist-get entry :body) t)
          (let* ((effects (emacs-hypervisor-effect-registry-effects-for-unit
                           "source-hook-unit"))
                 (source (plist-get (car effects) :source)))
            (should (= (length effects) 1))
            (should (equal (plist-get source :file) "config.org"))
            (should (equal (plist-get source :heading) "Hooks"))
            (should (equal (plist-get source :line) 14))
            (should (equal (plist-get source :form)
                           '(add-hook 'emacs-hypervisor-test-source-hook
                                      #'ignore)))))
      (emacs-hypervisor-effect-registry-retract-unit "source-hook-unit")
      (setq emacs-hypervisor-effect-registry-current registry))))

(require 'emacs-hypervisor-lint)

(ert-deftest emacs-hypervisor-lint-flags-untracked-and-suspect-forms ()
  (emacs-hypervisor-reset-declarations)
  ;; The hook below hides inside a lambda, so the effect rewriter cannot
  ;; reach it and lint should flag it as untracked.
  (eval '(config-unit! linted-unit
           :config
           (eval-after-load 'magit '(message "loaded"))
           (setq fancy-minor-mode t)
           (global-set-key (kbd "C-c x") (lambda ()
                                           (add-hook 'prog-mode-hook
                                                     (lambda () nil)))))
        t)
  (let* ((findings (emacs-hypervisor-lint-exported-declarations))
         (rules (mapcar (lambda (f) (plist-get f :rule)) findings)))
    (should (memq :eval-after-load rules))
    (should (memq :minor-mode-setq rules))
    (should (memq :untracked-anonymous-hook rules))
    (dolist (finding findings)
      (should (equal (plist-get finding :unit) "linted-unit"))
      (should (eq (plist-get finding :severity) :warning))
      (should (stringp (plist-get finding :form-string))))))

(ert-deftest emacs-hypervisor-lint-leaves-duplicates-to-boot-policy ()
  ;; Duplicate detection lives in Elle's boot policy (planned :invalid
  ;; reports with :duplicate-name), not in the Emacs-side lint pass.
  (emacs-hypervisor-reset-declarations)
  (eval '(progn
           (config-unit! dup-unit :config t)
           (config-unit! dup-unit :config 2))
        t)
  (should (null (emacs-hypervisor-lint-exported-declarations))))

(ert-deftest emacs-hypervisor-lint-leaves-clean-config-unflagged ()
  (emacs-hypervisor-reset-declarations)
  (eval '(progn
           (package! magit)
           (config-unit! clean-unit
             :requires (magit)
             :config
             (add-hook 'prog-mode-hook #'display-line-numbers-mode)
             (keymap-set global-map "C-x g" #'magit-status)))
        t)
  (should (null (emacs-hypervisor-lint-exported-declarations))))

(ert-deftest emacs-hypervisor-session-data-exports-lint-when-requested ()
  (emacs-hypervisor-reset-declarations)
  (eval '(config-unit! lint-export-unit
           :config
           (eval-after-load 'magit '(message "x")))
        t)
  (let ((payload (emacs-hypervisor-export-session-data '(:units :lint))))
    (should (plist-member payload :lint))
    (should (= (length (plist-get payload :lint)) 1)))
  ;; Lint stays out of the default startup payload.
  (should-not (plist-member
               (emacs-hypervisor-export-session-data '(:units))
               :lint)))

(ert-deftest emacs-hypervisor-check-exit-code-and-render ()
  (emacs-hypervisor-test--eval-home-startup-functions)
  (let ((clean '(:reason :check-complete :status :ok
                 :check (:packages-total 2 :units-total 3
                         :package-problems nil :unit-problems nil :lint nil)))
        (broken '(:reason :check-complete :status :failed
                  :check (:packages-total 1 :units-total 2
                          :package-problems ((:name "transient" :status :invalid
                                              :reason :cycle))
                          :unit-problems ((:name "magit-ui" :status :skipped
                                           :reason :preflight))
                          :lint nil)))
        (warned '(:reason :check-complete :status :ok
                  :check (:packages-total 0 :units-total 1
                          :package-problems nil :unit-problems nil
                          :lint ((:unit "editing" :rule :eval-after-load
                                  :severity :warning
                                  :message "prefer with-eval-after-load"))))))
    (should (= (emacs-hypervisor--check-exit-code clean) 0))
    (should (= (emacs-hypervisor--check-exit-code broken) 1))
    (should (= (emacs-hypervisor--check-exit-code warned) 0))
    (cl-letf (((symbol-function 'emacs-hypervisor--check-strict-p)
               (lambda () t)))
      (should (= (emacs-hypervisor--check-exit-code warned) 1)))
    (let ((rendered (with-output-to-string
                      (emacs-hypervisor--check-render-human broken))))
      (should (string-match-p "INVALID  package transient" rendered))
      (should (string-match-p "SKIPPED  unit magit-ui" rendered))
      (should (string-match-p "2 problems" rendered)))))

(require 'emacs-hypervisor-report)

(ert-deftest emacs-hypervisor-package-event-stores-rev-and-locked-extra ()
  (let ((emacs-hypervisor--package-events nil))
    (emacs-hypervisor-report-note-package-event
     :installed "magit" nil '(:rev "0aa2686deadbeef" :locked :hit))
    (let ((event (car emacs-hypervisor--package-events)))
      (should (equal (plist-get event :rev) "0aa2686deadbeef"))
      (should (eq (plist-get event :locked) :hit))
      (should (equal (emacs-hypervisor--package-revision-label event)
                     "0aa2686 (locked)")))
    (should (equal (emacs-hypervisor--package-revision-label
                    '(:rev "abc1234" :locked :pinned))
                   "abc1234 (pinned)"))
    (should (equal (emacs-hypervisor--package-revision-label
                    '(:rev "abc1234" :locked :miss))
                   "abc1234"))
    (should (null (emacs-hypervisor--package-revision-label '(:locked :hit))))))

(ert-deftest emacs-hypervisor-report-renders-package-revision-and-orphans ()
  (let ((emacs-hypervisor--package-events
         (list '(:kind :orphaned :reason "stale-pkg, old-tool" :time 2.0)
               '(:kind :installed :name "magit" :time 1.0
                 :rev "0aa2686deadbeef" :locked :hit)))
        (emacs-hypervisor--session-started-at 0.0))
    (with-temp-buffer
      (emacs-hypervisor--insert-package-activity-line "magit" :installed)
      (should (string-match-p "magit.*0aa2686 (locked)" (buffer-string))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'emacs-hypervisor--package-progress-summary)
                 (lambda () '(:plan-known nil)))
                ((symbol-function 'emacs-hypervisor--package-plan-names)
                 (lambda () nil))
                ((symbol-function 'emacs-hypervisor--package-state)
                 (lambda () "Ready")))
        (emacs-hypervisor--insert-packages-section))
      (should (string-match-p "Orphaned" (buffer-string)))
      (should (string-match-p "stale-pkg, old-tool" (buffer-string)))
      (should (string-match-p "emacs-hypervisor-prune-packages"
                              (buffer-string))))))

(ert-deftest emacs-hypervisor-report-problem-includes-source-button ()
  (let* ((source-dir (make-temp-file "hypervisor-report-source" t))
         (org-file (expand-file-name "config.org" source-dir)))
    (unwind-protect
        (progn
          (with-temp-file org-file
            (insert "* Magit\nline two\nline three\n"))
          (let ((emacs-hypervisor--state :completed)
                (emacs-hypervisor--report-messages
                 (list
                  (list :report :stage :executed :phase :units
                        :items
                        (list (list :name "broken-unit"
                                    :status :failed
                                    :reason :execution
                                    :details '(:source :eval :error "boom")
                                    :source (list :file org-file
                                                  :heading "Magit"
                                                  :line 3)))))))
            (with-temp-buffer
              (emacs-hypervisor--insert-problems-section)
              (should (string-match-p "broken-unit" (buffer-string)))
              (should (string-match-p "config\\.org · Magit · line 3"
                                      (buffer-string)))
              (goto-char (point-min))
              (let ((button (next-button (point))))
                (should button)
                (should (equal (plist-get
                                (button-get button 'emacs-hypervisor-source)
                                :line)
                               3))
                ;; Activating the button visits the file at the line.
                (save-window-excursion
                  (button-activate button)
                  (should (equal (buffer-file-name) org-file))
                  (should (= (line-number-at-pos) 3))
                  (kill-buffer))))))
      (delete-directory source-dir t))))

(ert-deftest emacs-hypervisor-report-formats-duplicate-name-reason ()
  (should (equal (emacs-hypervisor--format-reason-and-details
                  :duplicate-name '(:occurrences 2))
                 "declared 2 times")))
