;;; emacs-hypervisor-package-lock.el --- Package lockfile -*- lexical-binding: t; -*-

;;; Commentary:
;; Read and write `hypervisor.lock', the record of concretely installed
;; package revisions.  The lock lives in the user-owned Hypervisor config
;; directory so it travels with the dotfiles repo.  Entries are sorted by
;; name and rewritten atomically so VCS diffs stay stable.

(require 'cl-lib)
(require 'emacs-hypervisor-config-paths)

(defconst emacs-hypervisor-package-lock-schema-version 1)

(defvar emacs-hypervisor-package-lock-file nil
  "Override path for the package lockfile.  Nil uses the config directory.")

(defun emacs-hypervisor-package-lock--file ()
  (or emacs-hypervisor-package-lock-file
      (expand-file-name "hypervisor.lock"
                        (emacs-hypervisor--config-directory))))

(defun emacs-hypervisor-package-lock-read ()
  "Return the parsed lock plist, or nil when absent or unreadable.
A lockfile written with a different schema version is treated as
unreadable: adopting it would rewrite the file and destroy fields this
code does not know about."
  (let ((file (emacs-hypervisor-package-lock--file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (let* ((data (read (current-buffer)))
                   (version (and (listp data)
                                 (plist-get data :schema-version))))
              (cond
               ((null version) nil)
               ((not (equal version
                             emacs-hypervisor-package-lock-schema-version))
                (display-warning
                 'emacs-hypervisor
                 (format "Ignoring lockfile %s: schema version %S, expected %S"
                         file version
                         emacs-hypervisor-package-lock-schema-version))
                nil)
               (t data))))
        (error nil)))))

(defun emacs-hypervisor-package-lock-entries ()
  (plist-get (emacs-hypervisor-package-lock-read) :entries))

(defun emacs-hypervisor-package-lock-entry (name)
  "Return the lock entry plist for package NAME, or nil."
  (cl-find name (emacs-hypervisor-package-lock-entries)
           :key (lambda (entry) (plist-get entry :name))
           :test #'equal))

(defun emacs-hypervisor-package-lock--write (entries)
  "Write ENTRIES sorted by name, atomically (temp file + rename)."
  (let* ((file (emacs-hypervisor-package-lock--file))
         (directory (file-name-directory file))
         (sorted (sort (copy-sequence entries)
                       (lambda (a b)
                         (string< (plist-get a :name) (plist-get b :name)))))
         (payload (list :schema-version
                        emacs-hypervisor-package-lock-schema-version
                        :entries sorted)))
    (make-directory directory t)
    (let ((temp-file (make-temp-file
                      (expand-file-name ".hypervisor.lock." directory))))
      (with-temp-file temp-file
        (let ((print-length nil)
              (print-level nil))
          (insert ";; -*- mode: lisp-data -*-\n")
          (pp payload (current-buffer))))
      (rename-file temp-file file t))
    payload))

(defun emacs-hypervisor-package-lock-put (entry)
  "Insert or replace the lock entry for ENTRY's `:name'."
  (let* ((name (plist-get entry :name))
         (others (cl-remove name (emacs-hypervisor-package-lock-entries)
                            :key (lambda (e) (plist-get e :name))
                            :test #'equal)))
    (emacs-hypervisor-package-lock--write (cons entry others))
    entry))

(defun emacs-hypervisor-package-lock-remove (name)
  "Remove the lock entry for package NAME when present."
  (let ((entries (emacs-hypervisor-package-lock-entries)))
    (when (cl-find name entries
                   :key (lambda (e) (plist-get e :name))
                   :test #'equal)
      (emacs-hypervisor-package-lock--write
       (cl-remove name entries
                  :key (lambda (e) (plist-get e :name))
                  :test #'equal)))))

(provide 'emacs-hypervisor-package-lock)
