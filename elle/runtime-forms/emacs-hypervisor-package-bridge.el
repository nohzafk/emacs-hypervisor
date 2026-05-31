;;; emacs-hypervisor-package-bridge.el --- package.el/package-vc bridge -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'package)
(require 'package-vc)

;; `package-vc' generates `<pkg>-pkg.el' and the `<pkg>-autoloads.el' indirection
;; shim without a `lexical-binding' cookie, so `package--compile' (which runs
;; `byte-recompile-directory' over the whole package tree) emits a spurious
;; "file has no `lexical-binding' directive" warning for every VC package -- even
;; though those files carry `no-byte-compile: t'.  Binding this internal bytecomp
;; flag (Emacs 28+) around our install calls silences only that cookie warning;
;; real source-quality warnings (e.g. wide docstrings) are left untouched.
;; Forward-declared so dynamic binding works without eagerly loading `bytecomp'.
(defvar bytecomp--inhibit-lexical-cookie-warning)

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

(defun emacs-hypervisor-bridge--state-root ()
  (emacs-hypervisor-bridge--ensure-directory
   (expand-file-name "hypervisor/" user-emacs-directory)))

(defun emacs-hypervisor-bridge--staging-root ()
  (emacs-hypervisor-bridge--ensure-directory
   (expand-file-name "sources/" (emacs-hypervisor-bridge--state-root))))

(defun emacs-hypervisor-bridge--package-root ()
  (emacs-hypervisor-bridge--ensure-directory
   (expand-file-name "packages/" (emacs-hypervisor-bridge--state-root))))

(defun emacs-hypervisor-bridge--configure ()
  "Configure package.el paths and archives for the current Hypervisor home."
  (emacs-hypervisor-bridge--ensure-directory user-emacs-directory)
  (let ((expected-package-dir (emacs-hypervisor-bridge--package-root)))
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

(defun emacs-hypervisor-bridge--vc-spec (entry)
  "Return the `package-vc-selected-packages' spec for ENTRY."
  (append
   (list :url (emacs-hypervisor-bridge--build-url entry))
   (when (plist-get entry :branch)
     (list :branch (plist-get entry :branch)))
   (when (plist-get entry :ref)
     (list :rev (plist-get entry :ref)))
   (when (plist-get entry :lisp-dir)
     (list :lisp-dir (plist-get entry :lisp-dir)))))

(defun emacs-hypervisor-bridge--register-vc-spec (entry)
  "Register ENTRY in `package-vc-selected-packages' when it is VC-backed."
  (when (emacs-hypervisor-bridge--vc-entry-p entry)
    (let ((spec (emacs-hypervisor-bridge--vc-spec entry)))
      (when spec
        (setf (alist-get (emacs-hypervisor-bridge--package-symbol entry)
                         package-vc-selected-packages)
              spec)))))

(defun emacs-hypervisor-bridge--entry-lisp-dir (entry)
  "Return ENTRY's expanded package lisp directory, or nil."
  (when-let ((lisp-dir (plist-get entry :lisp-dir)))
    (expand-file-name lisp-dir (emacs-hypervisor-bridge--package-dir entry))))

(defun emacs-hypervisor-bridge--activate-entry-load-path (entry)
  "Add ENTRY's package lisp directory to `load-path' when declared."
  (when-let ((lisp-dir (emacs-hypervisor-bridge--entry-lisp-dir entry)))
    (when (file-directory-p lisp-dir)
      (add-to-list 'load-path (file-name-as-directory lisp-dir)))))

(defun emacs-hypervisor-bridge--activate-package-load-path (entry)
  "Add ENTRY's package root to `load-path' when package.el has not yet done so."
  (let ((dir (emacs-hypervisor-bridge--package-dir entry)))
    (when (file-directory-p dir)
      (add-to-list 'load-path (file-name-as-directory dir)))))

(defun emacs-hypervisor-bridge--activate-package (entry)
  "Activate ENTRY through package.el when it is known to package.el."
  (let ((sym (emacs-hypervisor-bridge--package-symbol entry)))
    (when (and (fboundp 'package-activate)
               (package-installed-p sym))
      (ignore-errors
        (package-activate sym)))))

(defun emacs-hypervisor-bridge--note-present (entry)
  "Apply runtime metadata for ENTRY that is already present."
  (emacs-hypervisor-bridge--register-vc-spec entry)
  (emacs-hypervisor-bridge--activate-package entry)
  (emacs-hypervisor-bridge--activate-package-load-path entry)
  (emacs-hypervisor-bridge--activate-entry-load-path entry))

(defun emacs-hypervisor-bridge--installed-p (entry)
  (let ((sym (emacs-hypervisor-bridge--package-symbol entry)))
    (or (package-installed-p sym)
        (file-directory-p (emacs-hypervisor-bridge--package-dir entry)))))

(defun emacs-hypervisor-bridge--clone-present-p (entry)
  (file-directory-p (emacs-hypervisor-bridge--clone-dir entry)))

(defun emacs-hypervisor-bridge--clone-command (entry)
  (let* ((url    (emacs-hypervisor-bridge--build-url entry))
         (branch (plist-get entry :branch))
         (ref    (plist-get entry :ref))
         (dir    (emacs-hypervisor-bridge--clone-dir entry)))
    (append (list "git" "clone")
            (unless ref
              (list "--depth" "1" "--no-single-branch"))
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

(defun emacs-hypervisor-bridge--run-in-clone (entry command label)
  "Run shell COMMAND inside ENTRY's clone directory.
LABEL identifies the step in error messages and the output buffer.  Signals an
error containing the captured output when COMMAND exits non-zero."
  (let* ((name (plist-get entry :name))
         (default-directory
          (file-name-as-directory (emacs-hypervisor-bridge--clone-dir entry)))
         (buffer (get-buffer-create (format " *hypervisor-%s-%s*" label name))))
    (with-current-buffer buffer (erase-buffer))
    (let ((status (call-process shell-file-name nil buffer nil
                                shell-command-switch command)))
      (unless (zerop status)
        (error "%s for %s failed (exit %d): %s"
               label name status
               (string-trim (with-current-buffer buffer (buffer-string))))))))

(defun emacs-hypervisor-bridge--prepare-checkout (entry)
  "Initialise submodules and run the build step declared by ENTRY.
`:submodules' (non-nil) initialises git submodules recursively, since
`package-vc' does not fetch them.  `:build' is a shell command, or a list of
shell commands, run in the package root -- e.g. to compile a native or
WebAssembly artifact that is not committed to the repository.  Both run before
`package-vc-install-from-checkout' so the artifacts are present when the
package is symlinked, byte-compiled, and activated."
  (when (plist-get entry :submodules)
    (emacs-hypervisor-bridge--run-in-clone
     entry "git submodule update --init --recursive" "submodules"))
  (let ((build (plist-get entry :build)))
    (dolist (command (if (listp build) build (list build)))
      (when (and command (stringp command))
        (emacs-hypervisor-bridge--run-in-clone entry command "build")))))

(defun emacs-hypervisor-bridge--adopt (entry)
  "Adopt a pre-cloned ENTRY via `package-vc-install-from-checkout'."
  (let* ((sym (emacs-hypervisor-bridge--package-symbol entry))
         (dir (emacs-hypervisor-bridge--clone-dir entry)))
    (unless (package-installed-p sym)
      ;; Fetch submodules and build any compiled artifact in the checkout before
      ;; package-vc symlinks and byte-compiles it.
      (emacs-hypervisor-bridge--prepare-checkout entry)
      ;; `package-vc-install-from-checkout' only accepts DIR and NAME in Emacs
      ;; 30.  Register the spec first so package-vc can still see :lisp-dir
      ;; during its unpack step.
      (emacs-hypervisor-bridge--register-vc-spec entry)
      (let ((bytecomp--inhibit-lexical-cookie-warning t))
        (package-vc-install-from-checkout dir (symbol-name sym))))
    (emacs-hypervisor-bridge--note-present entry)))

(defun emacs-hypervisor-bridge--archive-install (entry)
  (let ((sym (emacs-hypervisor-bridge--package-symbol entry)))
    (unless (package-installed-p sym)
      (let ((bytecomp--inhibit-lexical-cookie-warning t))
        (package-install sym)))
    (emacs-hypervisor-bridge--note-present entry)))

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
  (let (to-clone clone-results)
    (dolist (entry entries)
      (when (and (not (emacs-hypervisor-bridge--installed-p entry))
                 (emacs-hypervisor-bridge--vc-entry-p entry)
                 (not (emacs-hypervisor-bridge--clone-present-p entry)))
        (push entry to-clone)))
    ;; Network-only clone work can run in parallel; install/adopt still follows
    ;; the dependency-ordered plan from Elle below.
    (emacs-hypervisor-bridge--pump-clones
     (nreverse to-clone)
     (lambda (entry status) (push (cons entry status) clone-results)))
    (dolist (entry entries)
      (let* ((name (plist-get entry :name))
             (clone-status (cdr (assoc entry clone-results))))
        (cond
         ((emacs-hypervisor-bridge--installed-p entry)
          (emacs-hypervisor-bridge--note-present entry)
          (funcall on-installed name))
         ((and clone-status (not (eq clone-status :ok)))
          (funcall on-failed name (cadr clone-status)))
         ((emacs-hypervisor-bridge--vc-entry-p entry)
          (condition-case err
              (progn
                (emacs-hypervisor-bridge--adopt entry)
                (funcall on-installed name))
            (error
             (funcall on-failed name (format "%S" err)))))
         (t
          (condition-case err
              (progn
                (emacs-hypervisor-bridge--archive-install entry)
                (funcall on-installed name))
            (error
             (funcall on-failed name (format "%S" err))))))))
    :done))

(provide 'emacs-hypervisor-package-bridge)
