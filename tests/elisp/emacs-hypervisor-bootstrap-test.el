;;; emacs-hypervisor-bootstrap-test.el --- Bootstrap/runtime regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-bootstrap)

(defconst emacs-hypervisor-test--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defvar elpaca-recipe-functions nil)
(defvar elpaca--post-queues-hook nil)
(defvar elpaca-log-functions nil)
(defvar elpaca-after-init-time nil)
(defvar emacs-hypervisor-installed-packages nil)
(defvar emacs-hypervisor-execution-events nil)
(defvar emacs-hypervisor-test-runtime-value nil)
(defvar emacs-hypervisor-test-unchanged-counter nil)

(defun emacs-hypervisor-elpaca-bootstrap ()
  t)

(defun emacs-hypervisor-elpaca-infer-main-file (_recipe)
  nil)

(defun elpaca--shared-source-dir (&rest _args)
  nil)

(defun elpaca-source (&rest _args)
  nil)

(defun elpaca-git--clone (&rest _args)
  nil)

(defun emacs-hypervisor-elpaca-shared-source-dir (orig-fn id dir)
  (funcall orig-fn id dir))

(defun emacs-hypervisor-elpaca-wait-for-shared-git-source (orig-fn entry)
  (funcall orig-fn entry))

(defun emacs-hypervisor-elpaca-wait-on-shared-main-before-clone (orig-fn entry)
  (funcall orig-fn entry))

(defun elpaca-process-queues ()
  :processed)

(require 'emacs-hypervisor-package-runtime)
(require 'emacs-hypervisor-effect-registry)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-kind-hook)
(require 'emacs-hypervisor-effect-kind-advice)
(require 'emacs-hypervisor-effect-kind-keybinding)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-unit-runtime)
(require 'emacs-hypervisor-compose)
(require 'emacs-hypervisor-report)

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

(ert-deftest emacs-hypervisor-config-unit-export-wraps-supported-effect-lambdas ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! lambda-hook-unit
    :config
    (add-hook 'emacs-hypervisor-test-hook
              (lambda ()
                :hook)))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body))
         (hook-form (nth 1 body)))
    (should (eq (car hook-form) 'emacs-hypervisor-register-hook-effect))
    (should (equal (plist-get (cdr hook-form) :unit) "lambda-hook-unit"))
    (should (equal (plist-get (cdr hook-form) :target)
                   '(quote emacs-hypervisor-test-hook)))
    (should (equal (car (plist-get (cdr hook-form) :function))
                   'lambda))
    (should (equal (nth 2 body) t))))

(ert-deftest emacs-hypervisor-effect-aware-reload-has-registry-effect-specs ()
  (let* ((specs
          emacs-hypervisor-effect-aware-reload-effect-specs)
         (kinds (mapcar (lambda (spec) (plist-get spec :kind)) specs))
         (body
          (emacs-hypervisor-effect-aware-reload-normalize-body
           "effect-spec-unit"
           '(progn
              (add-hook 'emacs-hypervisor-test-hook
                        #'emacs-hypervisor-test-hook-new)
              (advice-add 'emacs-hypervisor-test-advice-target
                          :before
                          #'ignore)
              (keymap-set emacs-hypervisor-test-keymap
                          "C-c h"
                          #'emacs-hypervisor-test-command-old)
              t))))
    (should (equal kinds
                   '(:hook
                     :advice
                     :keybinding
                     :keybinding
                     :keybinding
                     :keybinding)))
    (should
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(add-hook 'emacs-hypervisor-test-hook
                 #'emacs-hypervisor-test-hook-new)))
    (should-not
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(add-hook 'emacs-hypervisor-test-hook
                 #'emacs-hypervisor-test-hook-new
                 nil
                 t)))
    (should
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(advice-add 'emacs-hypervisor-test-advice-target
                   :before
                   #'ignore)))
    (should
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(keymap-set emacs-hypervisor-test-keymap
                   "C-c h"
                   #'emacs-hypervisor-test-command-old)))
    (should
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(global-set-key (kbd "C-c h")
                       #'emacs-hypervisor-test-command-old)))
    (should-not
     (emacs-hypervisor-effect-aware-reload--registry-effect-form-p
      '(keymap-set emacs-hypervisor-test-keymap "C-c h")))
    (should (eq (car (nth 1 body))
                'emacs-hypervisor-register-hook-effect))
    (should (eq (car (nth 2 body))
                'emacs-hypervisor-register-advice-effect))
    (should (eq (car (nth 3 body))
                'emacs-hypervisor-register-keybinding-effect))))

(ert-deftest emacs-hypervisor-effect-registry-generated-name-is-deterministic ()
  (let* ((lambda-form '(lambda () :hook))
         (same
          (emacs-hypervisor-effect-registry--generated-function-symbol
           "lambda-hook-unit"
           :hook
           'emacs-hypervisor-test-hook
           nil
           lambda-form))
         (repeat
          (emacs-hypervisor-effect-registry--generated-function-symbol
           "lambda-hook-unit"
           :hook
           'emacs-hypervisor-test-hook
           nil
           lambda-form))
         (different-target
          (emacs-hypervisor-effect-registry--generated-function-symbol
           "lambda-hook-unit"
           :hook
           'emacs-hypervisor-other-hook
           nil
           lambda-form))
         (different-body
          (emacs-hypervisor-effect-registry--generated-function-symbol
           "lambda-hook-unit"
           :hook
           'emacs-hypervisor-test-hook
           nil
           '(lambda () :changed))))
    (should (eq same repeat))
    (should-not (eq same different-target))
    (should-not (eq same different-body))
    (should
     (string-match-p
      "\\`emacs-hypervisor--generated-lambda-hook-unit--hook-emacs-hypervisor-test-hook-[[:xdigit:]]\\{10\\}\\'"
      (symbol-name same)))))

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

(ert-deftest emacs-hypervisor-config-unit-export-canonicalizes-empty-brace-symbol ()
  (emacs-hypervisor-reset-declarations)
  (config-unit! empty-brace-symbol-unit
    :config
    (setq emacs-hypervisor-test-runtime-value '{}))
  (let* ((unit (car (emacs-hypervisor-export-config-units)))
         (body (plist-get unit :body)))
    (should (equal body
                   '(progn
                      (setq emacs-hypervisor-test-runtime-value
                            (intern "{}"))
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

(ert-deftest emacs-hypervisor-effect-aware-reload-counts-generic-cleaned-effects ()
  (should
   (=
    (emacs-hypervisor-effect-aware-reload-cleanup-count
     '(:cleaned ((:kind :hook)
                 (:kind :keybinding))))
    2)))

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

(ert-deftest emacs-hypervisor-effect-aware-reload-installs-keybinding-effect ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0))
    (emacs-hypervisor-reset-declarations)
    (config-unit! keybinding-unit
      :config
      (keymap-set emacs-hypervisor-test-keymap
                  "C-c h"
                  #'emacs-hypervisor-test-command-old))
    (let* ((unit (car (emacs-hypervisor-export-config-units)))
           (body (plist-get unit :body)))
      (eval body t)
      (let ((effects
             (emacs-hypervisor-effect-registry-effects-for-unit
              "keybinding-unit")))
        (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                    #'emacs-hypervisor-test-command-old))
        (should (= (length effects) 1))
        (should (eq (plist-get (car effects) :kind) :keybinding))
        (should (equal (plist-get (plist-get (car effects) :metadata) :key)
                       "C-c h"))))))

(ert-deftest emacs-hypervisor-effect-registry-reset-clears-keybinding-state ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0))
    (emacs-hypervisor-register-keybinding-effect
     :unit "keybinding-unit"
     :operator 'keymap-set
     :map emacs-hypervisor-test-keymap
     :map-form 'emacs-hypervisor-test-keymap
     :key "C-c h"
     :definition #'emacs-hypervisor-test-command-old
     :source '(:form (keymap-set emacs-hypervisor-test-keymap
                                  "C-c h"
                                  #'emacs-hypervisor-test-command-old)))
    (should (= (hash-table-count
                emacs-hypervisor-effect-kind-keybinding--states)
               1))
    (emacs-hypervisor-effect-registry-reset)
    (should (= (hash-table-count
                emacs-hypervisor-effect-kind-keybinding--states)
               0))))

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

(ert-deftest emacs-hypervisor-effect-aware-reload-removed-keybinding-unsets-new-binding ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0)
         previous)
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
    (emacs-hypervisor--reload-unit-reports
     (emacs-hypervisor-selective-reload-diff-units previous nil)
     nil)
    (should-not
     (emacs-hypervisor-effect-kind-keybinding--lookup
      emacs-hypervisor-test-keymap
      "C-c h"
      'keymap-set))))

(ert-deftest emacs-hypervisor-effect-aware-reload-keybinding-divergence-guard-preserves-external-binding ()
  (let* ((emacs-hypervisor-test-keymap (make-sparse-keymap))
         (emacs-hypervisor-effect-registry-current nil)
         (emacs-hypervisor-effect-registry--instance-counter 0)
         (emacs-hypervisor-effect-kind-keybinding--states
          (make-hash-table :test 'equal))
         (emacs-hypervisor-effect-kind-keybinding--state-counter 0)
         previous
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
      (emacs-hypervisor--reload-unit-reports
       (emacs-hypervisor-selective-reload-diff-units previous nil)
       nil))
    (should (eq (keymap-lookup emacs-hypervisor-test-keymap "C-c h")
                #'emacs-hypervisor-test-command-external))
    (should (equal (caar warnings) 'emacs-hypervisor))
    (should (string-match-p "Skipped keybinding cleanup"
                            (cadar warnings)))))

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

(ert-deftest emacs-hypervisor-report-session-finished-accepts-side-effecting-initial-choice ()
  (let ((emacs-hypervisor-show-report-on-startup nil)
        (emacs-hypervisor-display-initial-buffer-on-finish t)
        (emacs-hypervisor--state :completed)
        (noninteractive nil)
        (initial-buffer-choice
         (lambda ()
           (switch-to-buffer (get-buffer-create "*hypervisor-test-dashboard*"))
           nil)))
    (save-window-excursion
      (unwind-protect
          (progn
            (switch-to-buffer (get-buffer-create "*elpaca-log*"))
            (emacs-hypervisor-report-session-finished)
            (should (equal (buffer-name (window-buffer (selected-window)))
                           "*hypervisor-test-dashboard*"))
            (should-not (get-buffer-window "*elpaca-log*" t)))
        (when-let ((buffer (get-buffer "*hypervisor-test-dashboard*")))
          (kill-buffer buffer))
        (when-let ((buffer (get-buffer "*elpaca-log*")))
          (kill-buffer buffer))
        (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest emacs-hypervisor-report-session-started-does-not-open-report-when-enabled ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor-display-initial-buffer-on-finish t)
        (noninteractive nil)
        (initial-buffer-choice
         (lambda () (get-buffer-create "*hypervisor-test-dashboard*")))
        report-opened
        opened-buffer)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-opened t)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _args)
                 (setq opened-buffer buffer))))
      (unwind-protect
          (progn
            (emacs-hypervisor-report-session-started)
            (should-not report-opened)
            (should-not opened-buffer))
        (when-let ((buffer (get-buffer "*hypervisor-test-dashboard*")))
          (kill-buffer buffer))
        (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest emacs-hypervisor-report-package-begin-does-not-open-report-on-startup ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor--report-startup-opened nil)
        (noninteractive nil)
        report-opened)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-opened t))))
      (emacs-hypervisor-report-note-package-event :begin)
      (should-not report-opened))))

(ert-deftest emacs-hypervisor-report-package-finished-opens-report-on-startup-once ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor--report-startup-opened nil)
        (noninteractive nil)
        report-open-count)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-open-count (1+ (or report-open-count 0))))))
      (emacs-hypervisor-report-note-package-event :finished nil "completed")
      (emacs-hypervisor-report-note-unit-event :attempt "first-unit")
      (should (= report-open-count 1)))))

(ert-deftest emacs-hypervisor-report-unit-attempt-opens-report-on-startup-once ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor--report-startup-opened nil)
        (noninteractive nil)
        report-open-count)
    (cl-letf (((symbol-function 'emacs-hypervisor-open-report-buffer)
               (lambda ()
                 (setq report-open-count (1+ (or report-open-count 0))))))
      (emacs-hypervisor-report-note-unit-event :attempt "first-unit")
      (emacs-hypervisor-report-note-unit-event :attempt "second-unit")
      (should (= report-open-count 1)))))

(ert-deftest emacs-hypervisor-report-session-finished-does-not-open-report-when-enabled ()
  (let ((emacs-hypervisor-show-report-on-startup t)
        (emacs-hypervisor-display-initial-buffer-on-finish t)
        (emacs-hypervisor--state :completed)
        (noninteractive nil)
        report-opened
        opened-buffer)
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
            (should-not opened-buffer))
        (when-let ((buffer (get-buffer emacs-hypervisor--report-buffer-name)))
          (kill-buffer buffer))))))

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

(ert-deftest emacs-hypervisor-package-runtime-load-does-not-bootstrap-elpaca ()
  (let ((bootstrap-called nil)
        (emacs-hypervisor-runtime-package-timeout-timer nil))
    (cl-letf (((symbol-function 'emacs-hypervisor-elpaca-bootstrap)
               (lambda ()
                 (setq bootstrap-called t))))
      (load-file
       (expand-file-name
        "../../elle/runtime-forms/emacs-hypervisor-package-runtime.el"
        emacs-hypervisor-test--source-directory))
      (should-not bootstrap-called))))

(ert-deftest emacs-hypervisor-runtime-ensure-package-manager-bootstraps-on-demand ()
  (let ((emacs-hypervisor-runtime-package-manager-ready nil)
        (emacs-hypervisor-runtime-compat-enabled t)
        (elpaca--post-queues-hook nil)
        (bootstrap-calls 0))
    (cl-letf (((symbol-function 'emacs-hypervisor-elpaca-bootstrap)
               (lambda ()
                 (setq bootstrap-calls (1+ bootstrap-calls)))))
      (should (eq (emacs-hypervisor-runtime-ensure-package-manager) :ready))
      (should (= bootstrap-calls 1))
      (should emacs-hypervisor-runtime-package-manager-ready)
      (should (memq #'emacs-hypervisor-runtime-queues-finished
                    elpaca--post-queues-hook))
      (should (eq (emacs-hypervisor-runtime-ensure-package-manager) :ready))
      (should (= bootstrap-calls 1)))))

(ert-deftest emacs-hypervisor-runtime-ensure-package-manager-installs-log-suppression ()
  (let ((emacs-hypervisor-runtime-package-manager-ready t)
        (emacs-hypervisor-runtime-compat-enabled nil)
        (elpaca-recipe-functions nil)
        (elpaca--post-queues-hook nil)
        (elpaca-log-functions '(elpaca-log-initial-queues)))
    (unwind-protect
        (progn
          (should (eq (emacs-hypervisor-runtime-ensure-package-manager) :ready))
          (should
           (eq (car elpaca-log-functions)
               #'emacs-hypervisor-runtime-suppress-initial-elpaca-log-when-sources-present))
          (should
           (memq #'emacs-hypervisor-runtime-suppress-initial-elpaca-log-when-sources-present
                 elpaca-log-functions)))
      (advice-remove 'elpaca--shared-source-dir
                     #'emacs-hypervisor-elpaca-shared-source-dir)
      (advice-remove 'elpaca-source
                     #'emacs-hypervisor-elpaca-wait-for-shared-git-source)
      (advice-remove 'elpaca-git--clone
                     #'emacs-hypervisor-elpaca-wait-on-shared-main-before-clone))))

(ert-deftest emacs-hypervisor-runtime-suppresses-initial-elpaca-log-when-source-dirs-exist ()
  (let ((source-a (make-temp-file "emacs-hypervisor-source-a" t))
        (source-b (make-temp-file "emacs-hypervisor-source-b" t))
        (elpaca-after-init-time nil))
    (unwind-protect
        (cl-letf (((symbol-function 'elpaca--queued)
                   (lambda ()
                     `((pkg-a . (:source ,source-a :status queued))
                       (pkg-b . (:source ,source-b :status queued)))))
                  ((symbol-function 'elpaca<-source-dir)
                   (lambda (entry)
                     (plist-get entry :source)))
                  ((symbol-function 'elpaca--status)
                   (lambda (entry)
                     (plist-get entry :status))))
          (should-not (emacs-hypervisor-runtime-package-work-required-p))
          (should
           (eq (emacs-hypervisor-runtime-suppress-initial-elpaca-log-when-sources-present)
               'silent)))
      (delete-directory source-a t)
      (delete-directory source-b t))))

(ert-deftest emacs-hypervisor-runtime-keeps-initial-elpaca-log-when-source-dir-missing ()
  (let* ((root (make-temp-file "emacs-hypervisor-source-root" t))
         (source-a (expand-file-name "pkg-a" root))
         (source-b (expand-file-name "pkg-b" root))
         (elpaca-after-init-time nil))
    (make-directory source-a)
    (unwind-protect
        (cl-letf (((symbol-function 'elpaca--queued)
                   (lambda ()
                     `((pkg-a . (:source ,source-a :status queued))
                       (pkg-b . (:source ,source-b :status queued)))))
                  ((symbol-function 'elpaca<-source-dir)
                   (lambda (entry)
                     (plist-get entry :source)))
                  ((symbol-function 'elpaca--status)
                   (lambda (entry)
                     (plist-get entry :status))))
          (should (emacs-hypervisor-runtime-package-work-required-p))
          (should-not
           (emacs-hypervisor-runtime-suppress-initial-elpaca-log-when-sources-present)))
      (delete-directory root t))))

(ert-deftest emacs-hypervisor-runtime-process-packages-buries-noop-elpaca-log ()
  (let ((emacs-hypervisor-runtime-package-manager-ready t)
        (emacs-hypervisor-runtime-compat-enabled t)
        (emacs-hypervisor-execution-events nil)
        (emacs-hypervisor-runtime-package-timeout-seconds nil)
        (emacs-hypervisor-runtime-package-timeout-timer nil)
        (emacs-hypervisor-runtime-packages-installation-active nil)
        (emacs-hypervisor-runtime-packages-finished-sent nil)
        (initial-buffer-choice :dashboard)
        (elpaca--post-queues-hook nil))
    (save-window-excursion
      (cl-letf (((symbol-function 'emacs-hypervisor-runtime-package-work-required-p)
                 (lambda () nil))
                ((symbol-function 'elpaca-process-queues)
                 (lambda ()
                   (setq initial-buffer-choice
                         (lambda () (get-buffer-create "*elpaca-log*")))
                   (switch-to-buffer (get-buffer-create "*elpaca-log*"))
                   :processed)))
        (unwind-protect
            (progn
              (should (eq (emacs-hypervisor-runtime-process-packages)
                          :processing))
              (should (eq initial-buffer-choice :dashboard))
              (should-not (get-buffer-window "*elpaca-log*" t)))
          (when-let ((buffer (get-buffer "*elpaca-log*")))
            (kill-buffer buffer)))))))

(ert-deftest emacs-hypervisor-runtime-package-callbacks-emit-installed-and-finish-once ()
  (let ((emacs-hypervisor-runtime-package-manager-ready t)
        (emacs-hypervisor-runtime-compat-enabled t)
        sent
        noted)
    (setq emacs-hypervisor-installed-packages nil)
    (setq emacs-hypervisor-execution-events nil)
    (setq emacs-hypervisor-runtime-package-timeout-seconds nil)
    (setq emacs-hypervisor-runtime-package-timeout-timer nil)
    (setq emacs-hypervisor-runtime-packages-installation-active nil)
    (setq emacs-hypervisor-runtime-packages-finished-sent nil)
    (cl-letf (((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload)
                 (push (list topic payload) sent)))
              ((symbol-function 'emacs-hypervisor-runtime-note-package-event)
               (lambda (kind &optional name reason)
                 (push (list kind name reason) noted)))
              ((symbol-function 'elpaca-process-queues)
               (lambda ()
                 (push :process-queues noted)
                 :processed)))
      (should (eq (emacs-hypervisor-runtime-process-packages) :processing))
      (emacs-hypervisor-runtime-package-callback "core-pkg")
      (emacs-hypervisor-runtime-notify-packages-finished "completed")
      (emacs-hypervisor-runtime-notify-packages-finished "completed"))
    (setq sent (nreverse sent))
    (should (equal emacs-hypervisor-installed-packages '("core-pkg")))
    (should (equal (mapcar #'car sent) '(:package :package)))
    (should (equal (cadar sent)
                   '(:phase :packages :kind :installed :name "core-pkg")))
    (should (equal (cadadr sent)
                   '(:phase :packages :kind :finished :reason "completed")))
    (should (equal (car emacs-hypervisor-execution-events)
                   '(:phase :packages :event :finished :reason "completed")))))

(ert-deftest emacs-hypervisor-runtime-package-timeout-emits-timeout-event ()
  (let (sent)
    (setq emacs-hypervisor-runtime-package-timeout-seconds nil)
    (setq emacs-hypervisor-runtime-package-timeout-timer nil)
    (setq emacs-hypervisor-runtime-packages-installation-active nil)
    (setq emacs-hypervisor-runtime-packages-finished-sent nil)
    (cl-letf (((symbol-function 'emacs-hypervisor-send-event)
               (lambda (topic payload)
                 (push (list topic payload) sent))))
      (emacs-hypervisor-runtime-begin-package-installation)
      (emacs-hypervisor-runtime-package-timeout))
    (setq sent (nreverse sent))
    (should-not emacs-hypervisor-runtime-packages-installation-active)
    (should emacs-hypervisor-runtime-packages-finished-sent)
    (should (equal sent
                   '((:package
                      (:phase :packages :kind :timeout :reason "timeout")))))))
