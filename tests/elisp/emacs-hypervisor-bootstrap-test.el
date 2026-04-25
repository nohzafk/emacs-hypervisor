;;; emacs-hypervisor-bootstrap-test.el --- Bootstrap/runtime regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-bootstrap)

(defvar elpaca-recipe-functions nil)
(defvar elpaca--post-queues-hook nil)
(defvar emacs-hypervisor-installed-packages nil)
(defvar emacs-hypervisor-execution-events nil)
(defvar emacs-hypervisor-test-runtime-value nil)

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
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-unit-runtime)

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
    (eval body)
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
    (eval body)
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

(ert-deftest emacs-hypervisor-load-envvars-file-updates-runtime-environment ()
  (let* ((path-dir "/tmp/emacs-hypervisor-test-bin")
         (temp-file (make-temp-file "emacs-hypervisor-env" nil ".el"))
         (process-environment (copy-sequence process-environment))
         (exec-path (copy-sequence exec-path))
         (shell-file-name shell-file-name))
    (unwind-protect
        (progn
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
          (should (equal shell-file-name "/bin/fish"))
          (should (equal (car exec-path) path-dir))
          (should (equal emacs-hypervisor-loaded-env-file
                         (expand-file-name temp-file))))
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

(ert-deftest emacs-hypervisor-runtime-package-callbacks-emit-installed-and-finish-once ()
  (let (sent noted)
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
