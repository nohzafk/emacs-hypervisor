;;; emacs-hypervisor-package-bridge.el --- package.el/package-vc bridge -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'package)
(require 'package-vc)

(defvar emacs-hypervisor-bridge-ready nil)
(defvar emacs-hypervisor-bridge-activated nil)

(defcustom emacs-hypervisor-clone-concurrency 8
  "Maximum number of git clones run in parallel during package install."
  :type 'integer
  :group 'emacs-hypervisor)

(defcustom emacs-hypervisor-default-host "github"
  "Host assumed for `:repo' shorthand when no `:host' is given."
  :type 'string
  :group 'emacs-hypervisor)

(defvar emacs-hypervisor-bridge-archives
  '(("gnu"    . "https://elpa.gnu.org/packages/")
    ("nongnu" . "https://elpa.nongnu.org/nongnu/")
    ("melpa"  . "https://melpa.org/packages/"))
  "Archives configured when the bridge initializes.")

(defun emacs-hypervisor-bridge--ensure-directory (dir)
  (let ((path (file-name-as-directory (expand-file-name dir))))
    (make-directory path t)
    path))

(defun emacs-hypervisor-bridge--staging-root ()
  (emacs-hypervisor-bridge--ensure-directory
   (expand-file-name "packages-src/" user-emacs-directory)))

(defun emacs-hypervisor-bridge--configure ()
  "Configure package.el paths and archives for the current Hypervisor home."
  (emacs-hypervisor-bridge--ensure-directory user-emacs-directory)
  (let ((expected-package-dir
         (emacs-hypervisor-bridge--ensure-directory
          (expand-file-name "packages/" user-emacs-directory))))
    (unless (equal (file-name-as-directory (expand-file-name package-user-dir))
                   expected-package-dir)
      (setq package-user-dir expected-package-dir)
      (setq package--initialized nil)))
  (emacs-hypervisor-bridge--staging-root)
  (dolist (archive emacs-hypervisor-bridge-archives)
    (cl-pushnew archive package-archives :test #'equal))
  :configured)

(defun emacs-hypervisor-bridge-activate ()
  "Activate already installed Hypervisor packages without refreshing archives."
  (unless emacs-hypervisor-bridge-activated
    (emacs-hypervisor-bridge--configure)
    (unless package--initialized
      (package-initialize))
    (setq emacs-hypervisor-bridge-activated t))
  :activated)

(defun emacs-hypervisor-bridge-init ()
  "Configure package.el paths and archives for hypervisor-managed installs."
  (unless emacs-hypervisor-bridge-ready
    (emacs-hypervisor-bridge-activate)
    (unless package-archive-contents
      (package-refresh-contents))
    (setq emacs-hypervisor-bridge-ready t))
  :ready)

(defun emacs-hypervisor-bridge--host-base (host)
  (pcase (and host (downcase (format "%s" host)))
    ("github"    "https://github.com/")
    ("gitlab"    "https://gitlab.com/")
    ("codeberg"  "https://codeberg.org/")
    ("sourcehut" "https://git.sr.ht/~")
    (_           "https://github.com/")))

(defun emacs-hypervisor-bridge--local-repo-p (repo)
  (and (stringp repo)
       (or (string-prefix-p "/" repo)
           (string-prefix-p "~" repo)
           (string-prefix-p "./" repo)
           (string-prefix-p "../" repo))))

(defun emacs-hypervisor-bridge--expand-local (path)
  (expand-file-name path))

(defun emacs-hypervisor-bridge--build-url (entry)
  "Build a clone URL from ENTRY plist. Return nil for archive-only entries."
  (let ((repo  (plist-get entry :repo))
        (host  (plist-get entry :host))
        (local (plist-get entry :local)))
    (cond
     (local
      (concat "file://" (emacs-hypervisor-bridge--expand-local local)))
     ((emacs-hypervisor-bridge--local-repo-p repo)
      (concat "file://" (emacs-hypervisor-bridge--expand-local repo)))
     ((and (stringp repo) (string-match-p "://" repo))
      repo)
     ((stringp repo)
      (concat (emacs-hypervisor-bridge--host-base
               (or host emacs-hypervisor-default-host))
              repo))
     (t nil))))

(defun emacs-hypervisor-bridge--vc-entry-p (entry)
  (and (emacs-hypervisor-bridge--build-url entry) t))

(defun emacs-hypervisor-bridge--clone-dir (entry)
  (expand-file-name
   (plist-get entry :name)
   (emacs-hypervisor-bridge--staging-root)))

(defun emacs-hypervisor-bridge--package-dir (entry)
  (expand-file-name (plist-get entry :name) package-user-dir))

(defun emacs-hypervisor-bridge--package-symbol (entry)
  (intern (plist-get entry :name)))

(defun emacs-hypervisor-bridge--installed-p (entry)
  (let ((sym (emacs-hypervisor-bridge--package-symbol entry)))
    (or (package-installed-p sym)
        (file-directory-p (emacs-hypervisor-bridge--package-dir entry)))))

(defun emacs-hypervisor-bridge--clone-present-p (entry)
  (file-directory-p (emacs-hypervisor-bridge--clone-dir entry)))

(defun emacs-hypervisor-bridge--clone-command (entry)
  (let* ((url    (emacs-hypervisor-bridge--build-url entry))
         (branch (plist-get entry :branch))
         (dir    (emacs-hypervisor-bridge--clone-dir entry)))
    (append (list "git" "clone" "--depth" "1" "--no-single-branch")
            (when branch (list "--branch" branch))
            (list url dir))))

(defun emacs-hypervisor-bridge--checkout-ref (entry)
  "Run `git checkout' for :ref or :tag inside the cloned directory."
  (let ((ref (or (plist-get entry :ref) (plist-get entry :tag)))
        (dir (emacs-hypervisor-bridge--clone-dir entry)))
    (when ref
      (let* ((buffer (get-buffer-create
                      (format " *hypervisor-checkout-%s*"
                              (plist-get entry :name))))
             (default-directory dir)
             (status (call-process "git" nil buffer nil "checkout" ref)))
        (unless (zerop status)
          (let ((output (with-current-buffer buffer (buffer-string))))
            (kill-buffer buffer)
            (error "git checkout %s failed: %s" ref output)))
        (kill-buffer buffer)))))

(defun emacs-hypervisor-bridge--start-clone (entry on-done)
  "Spawn an async clone for ENTRY. Calls ON-DONE with :ok or (:error REASON)."
  (let* ((name   (plist-get entry :name))
         (buffer (get-buffer-create (format " *hypervisor-clone-%s*" name)))
         (handled nil))
    (with-current-buffer buffer (erase-buffer))
    (make-process
     :name (format "hypervisor-clone-%s" name)
     :buffer buffer
     :command (emacs-hypervisor-bridge--clone-command entry)
     :noquery t
     :sentinel
     (lambda (proc _event)
       (when (and (not handled)
                  (memq (process-status proc) '(exit signal)))
         (setq handled t)
         (let ((code (process-exit-status proc)))
           (if (zerop code)
               (condition-case err
                   (progn
                     (emacs-hypervisor-bridge--checkout-ref entry)
                     (when (buffer-live-p buffer)
                       (kill-buffer buffer))
                     (funcall on-done :ok))
                 (error
                  (when (buffer-live-p buffer)
                    (kill-buffer buffer))
                  (funcall on-done (list :error (format "%S" err)))))
             (let ((output (if (buffer-live-p buffer)
                               (with-current-buffer buffer (buffer-string))
                             "")))
               (when (buffer-live-p buffer)
                 (kill-buffer buffer))
               (funcall on-done
                        (list :error
                              (format "git clone exited %d: %s"
                                      code (string-trim output))))))))))))

(defun emacs-hypervisor-bridge--adopt (entry)
  "Adopt a pre-cloned ENTRY via `package-vc-install-from-checkout'."
  (let* ((sym (emacs-hypervisor-bridge--package-symbol entry))
         (dir (emacs-hypervisor-bridge--clone-dir entry))
         (spec (append
                (list :url (emacs-hypervisor-bridge--build-url entry))
                (when (plist-get entry :branch)
                  (list :branch (plist-get entry :branch)))
                (when (plist-get entry :lisp-dir)
                  (list :lisp-dir (plist-get entry :lisp-dir))))))
    (unless (package-installed-p sym)
      ;; `package-vc-install-from-checkout' only accepts DIR and NAME in Emacs
      ;; 30.  Register the spec first so package-vc can still see :lisp-dir
      ;; during its unpack step.
      (when spec
        (setf (alist-get sym package-vc-selected-packages) spec))
      (package-vc-install-from-checkout dir (symbol-name sym)))))

(defun emacs-hypervisor-bridge--archive-install (entry)
  (let ((sym (emacs-hypervisor-bridge--package-symbol entry)))
    (unless (package-installed-p sym)
      (package-install sym))))

(defun emacs-hypervisor-bridge--pump-clones (vc-entries on-each)
  "Run parallel clones for VC-ENTRIES. Call ON-EACH with (entry status).
Blocks until every entry has reported. STATUS is :ok or (:error REASON)."
  (let ((pending (copy-sequence vc-entries))
        (active 0)
        (limit  (max 1 emacs-hypervisor-clone-concurrency)))
    (cl-labels
        ((spawn-next ()
           (when (and pending (< active limit))
             (let ((entry (pop pending)))
               (cl-incf active)
               (emacs-hypervisor-bridge--start-clone
                entry
                (lambda (status)
                  (cl-decf active)
                  (funcall on-each entry status)
                  (spawn-next)))))))
      (dotimes (_ limit) (spawn-next))
      (while (> active 0)
        (accept-process-output nil 0.1)))))

(defun emacs-hypervisor-bridge-install-batch (entries on-installed on-failed)
  "Install ENTRIES. Call ON-INSTALLED with name when each succeeds.
Call ON-FAILED with (name reason) on failure."
  (emacs-hypervisor-bridge-init)
  (let (already to-clone to-adopt archive clone-results)
    (dolist (entry entries)
      (cond
       ((emacs-hypervisor-bridge--installed-p entry)
        (push entry already))
       ((emacs-hypervisor-bridge--vc-entry-p entry)
        (if (emacs-hypervisor-bridge--clone-present-p entry)
            (push entry to-adopt)
          (push entry to-clone)))
       (t (push entry archive))))
    ;; Packages already installed: emit immediately.
    (dolist (entry (nreverse already))
      (funcall on-installed (plist-get entry :name)))
    ;; Phase A: parallel clones for VC entries that aren't already cloned.
    (emacs-hypervisor-bridge--pump-clones
     (nreverse to-clone)
     (lambda (entry status) (push (cons entry status) clone-results)))
    ;; Adopt successful clones plus pre-existing checkouts.
    (dolist (pair (nreverse clone-results))
      (let ((entry (car pair)) (status (cdr pair)))
        (if (eq status :ok)
            (push entry to-adopt)
          (funcall on-failed
                   (plist-get entry :name)
                   (cadr status)))))
    ;; Phase B: serial adoption.
    (dolist (entry (nreverse to-adopt))
      (condition-case err
          (progn
            (emacs-hypervisor-bridge--adopt entry)
            (funcall on-installed (plist-get entry :name)))
        (error
         (funcall on-failed
                  (plist-get entry :name)
                  (format "%S" err)))))
    ;; Phase C: archive installs.
    (dolist (entry (nreverse archive))
      (condition-case err
          (progn
            (emacs-hypervisor-bridge--archive-install entry)
            (funcall on-installed (plist-get entry :name)))
        (error
         (funcall on-failed
                  (plist-get entry :name)
                  (format "%S" err)))))
    :done))

(provide 'emacs-hypervisor-package-bridge)
