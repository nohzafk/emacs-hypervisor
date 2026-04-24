;;; emacs-hypervisor-elpaca-bridge.el --- Elpaca bridge helpers -*- lexical-binding: t; -*-

(require 'cl-lib)

(defvar elpaca-installer-version 0.12)
(defconst emacs-hypervisor-elpaca-bootstrap-recipe
  '(elpaca :repo "https://github.com/progfolio/elpaca.git"
           :ref nil :depth 1 :inherit ignore
           :files (:defaults "elpaca-test.el" (:exclude "extensions"))
           :build (:not elpaca-activate)))

(defun emacs-hypervisor-elpaca--ensure-directory (dir)
  "Ensure DIR exists and return it as a directory name."
  (let ((path (file-name-as-directory (expand-file-name dir))))
    (make-directory path t)
    path))

(defun emacs-hypervisor-elpaca-root ()
  "Return the repo-local Elpaca root under `user-emacs-directory'."
  (expand-file-name "elpaca/" user-emacs-directory))

(defun emacs-hypervisor-elpaca--bootstrap-local-install ()
  "Bootstrap a local Elpaca install under the current repo-local root."
  (let* ((root (file-name-as-directory
                (emacs-hypervisor-elpaca--ensure-directory
                 (emacs-hypervisor-elpaca-root))))
         (repo (expand-file-name "sources/elpaca/" root))
         (build (expand-file-name "builds/elpaca/" root))
         (order (cdr emacs-hypervisor-elpaca-bootstrap-recipe))
         (default-directory repo))
    (add-to-list 'load-path (if (file-exists-p build) build repo))
    (unless (file-exists-p repo)
      (make-directory repo t)
      (when (<= emacs-major-version 28)
        (require 'subr-x))
      (condition-case-unless-debug err
          (if-let* ((buffer (get-buffer-create "*emacs-hypervisor-elpaca-bootstrap*"))
                    ((zerop
                      (apply #'call-process
                             (append
                              (list "git" nil buffer t "clone")
                              (when-let* ((depth (plist-get order :depth)))
                                (list (format "--depth=%d" depth)
                                      "--no-single-branch"))
                              (list (plist-get order :repo) repo)))))
                    ((zerop
                      (call-process "git" nil buffer t "checkout"
                                    (or (plist-get order :ref) "--"))))
                    (emacs (concat invocation-directory invocation-name))
                    ((zerop
                      (call-process emacs nil buffer nil "-Q" "-L" "."
                                    "--batch"
                                    "--eval"
                                    "(byte-recompile-directory \".\" 0 'force)")))
                    ((require 'elpaca))
                    ((elpaca-generate-autoloads "elpaca" repo)))
              (kill-buffer buffer)
            (error "%s" (with-current-buffer buffer (buffer-string))))
        (error
         (delete-directory repo 'recursive)
         (signal (car err) (cdr err))))))
  t)

(defun emacs-hypervisor-elpaca-bootstrap ()
  "Load Elpaca under the current repo-local `user-emacs-directory'."
  (let* ((user-dir (emacs-hypervisor-elpaca--ensure-directory user-emacs-directory))
         (root (file-name-as-directory
                (emacs-hypervisor-elpaca--ensure-directory
                 (emacs-hypervisor-elpaca-root))))
         (repo (expand-file-name "sources/elpaca/" root))
         (build (expand-file-name "builds/elpaca/" root))
         (default-directory repo))
    (setq user-emacs-directory user-dir)
    (emacs-hypervisor-elpaca--ensure-directory root)
    (emacs-hypervisor-elpaca--ensure-directory (expand-file-name "sources/" root))
    (emacs-hypervisor-elpaca--ensure-directory (expand-file-name "builds/" root))
    (emacs-hypervisor-elpaca--ensure-directory (expand-file-name "cache/" root))
    (emacs-hypervisor-elpaca--bootstrap-local-install)
    (add-to-list 'load-path (if (file-exists-p build) build repo))
    (unless (require 'elpaca-autoloads nil t)
      (require 'elpaca)
      (elpaca-generate-autoloads "elpaca" repo)
      (let ((load-source-file-function nil))
        (load "./elpaca-autoloads")))
    (require 'elpaca)))

(defun emacs-hypervisor-elpaca-infer-main-file (recipe)
  "Infer `:main' for split-package RECIPEs when Elpaca omits it."
  (unless (plist-member recipe :main)
    (when-let* ((package (plist-get recipe :package))
                (files (plist-get recipe :files))
                (package-name (if (symbolp package) (symbol-name package) package)))
      (let ((main-file nil))
        (while (and files (not main-file))
          (let ((file (car files)))
            (when (and (stringp file)
                       (string-match-p
                        (concat "\\(?:^\\|/\\)"
                                (regexp-quote package-name)
                                "\\.el\\'")
                        file))
              (setq main-file file)))
          (setq files (cdr files)))
        (when main-file
          (list :main main-file))))))

(defun emacs-hypervisor-elpaca--set-list-slot (entry index value)
  "Set list-backed Elpaca ENTRY slot at INDEX to VALUE."
  (setcar (nthcdr index entry) value))

(defun emacs-hypervisor-elpaca--push-blocker (entry blocker-id)
  "Record BLOCKER-ID in ENTRY's blocker list without setf accessors."
  (unless (memq blocker-id (elpaca<-blockers entry))
    (emacs-hypervisor-elpaca--set-list-slot
     entry 13 (cons blocker-id (elpaca<-blockers entry)))))

(defun emacs-hypervisor-elpaca--push-blocking (entry blocked-id)
  "Record BLOCKED-ID in ENTRY's blocking list without setf accessors."
  (unless (memq blocked-id (elpaca<-blocking entry))
    (emacs-hypervisor-elpaca--set-list-slot
     entry 12 (cons blocked-id (elpaca<-blocking entry)))))

(defun emacs-hypervisor-elpaca--set-statuses (entry statuses)
  "Set ENTRY statuses without relying on runtime gv setters."
  (emacs-hypervisor-elpaca--set-list-slot entry 5 statuses))

(defun emacs-hypervisor-elpaca-shared-source-dir (orig-fn id dir)
  "Return the nearest prior shared-source owner for ID at DIR."
  (let* ((queued (elpaca--queued))
         (index (cl-position id queued :key #'car :test #'eq))
         (current (and index (cdr (nth index queued)))))
    (if (not current)
        (funcall orig-fn id dir)
      (cl-loop for i from (- index 1) downto 0
               for e = (cdr (nth i queued))
               when (and e
                         (equal dir (elpaca<-source-dir e))
                         (<= (elpaca<-queue-id e) (elpaca<-queue-id current)))
               return e))))

(defun emacs-hypervisor-elpaca-wait-for-shared-git-source (orig-fn e)
  "Block E on an earlier queued git package sharing the same source checkout."
  (if (not (eq (plist-get (elpaca<-recipe e) :type) 'git))
      (funcall orig-fn e)
    (if-let* ((shared (elpaca--shared-source-dir
                       (elpaca<-id e)
                       (elpaca<-source-dir e)))
              ((not (or (memq (elpaca<-id shared) (elpaca<-blockers e))
                        (elpaca<-builtp shared)))))
        (progn
          (emacs-hypervisor-elpaca--push-blocker e (elpaca<-id shared))
          (emacs-hypervisor-elpaca--push-blocking shared (elpaca<-id e))
          (emacs-hypervisor-elpaca--set-statuses e (list 'blocked 'queued)))
      (funcall orig-fn e))))

(defun emacs-hypervisor-elpaca-wait-for-main-file (e main attempts)
  "Continue E once MAIN exists under its source dir, retrying ATTEMPTS times."
  (let ((file (expand-file-name main (elpaca<-source-dir e))))
    (cond
     ((file-exists-p file)
      (elpaca--continue-build e (format "Shared source ready: %s" main)))
     ((<= attempts 0)
      (elpaca--fail e (format "Timed out waiting for shared source file: %s" file)))
     (t
      (run-at-time 0.1 nil #'emacs-hypervisor-elpaca-wait-for-main-file
                   e main (- attempts 1))))))

(defun emacs-hypervisor-elpaca-wait-on-shared-main-before-clone (orig-fn e)
  "Delay clone-skip continuation until E's main file exists in the shared repo."
  (let* ((recipe (elpaca<-recipe e))
         (main (plist-get recipe :main))
         (source-dir (elpaca<-source-dir e))
         (main-file (and main (expand-file-name main source-dir))))
    (if (and main
             (file-exists-p source-dir)
             (not (file-exists-p main-file)))
        (progn
          (elpaca--signal e (format "%s exists. Waiting for %s." source-dir main)
                          'cloning)
          (emacs-hypervisor-elpaca-wait-for-main-file e main 600))
      (funcall orig-fn e))))

(provide 'emacs-hypervisor-elpaca-bridge)
