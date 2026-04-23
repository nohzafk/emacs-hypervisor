;; https://karthinks.com/software/avy-can-do-anything/

(setq avy-keys '(?q ?e ?r ?y ?u ?o ?p
                    ?a ?s ?d ?f ?g ?h ?j
                    ?k ?l ?' ?x ?c ?v ?b
                    ?n ?, ?/))

(defun avy-show-dispatch-help ()
  (let* ((len (length "avy-action-"))
         (fw (frame-width))
         (raw-strings (mapcar
                       (lambda (x)
                         (format "%2s: %-19s"
                                 (propertize
                                  (char-to-string (car x))
                                  'face 'aw-key-face)
                                 (substring (symbol-name (cdr x)) len)))
                       avy-dispatch-alist))
         (max-len (1+ (apply #'max (mapcar #'length raw-strings))))
         (strings-len (length raw-strings))
         (per-row (floor fw max-len))
         display-strings)
    (cl-loop for string in raw-strings
             for N from 1 to strings-len do
             (push (concat string " ") display-strings)
             (when (= (mod N per-row) 0) (push "\n" display-strings)))
    (message "%s" (apply #'concat (nreverse display-strings)))))

;; Copy text
(defun avy-action-copy-whole-line (pt)
  (save-excursion
    (goto-char pt)
    (cl-destructuring-bind (start . end)
        (bounds-of-thing-at-point 'line)
      (copy-region-as-kill start end)))
  (select-window
   (cdr
    (ring-ref avy-ring 0)))
  t)

(setf (alist-get ?w avy-dispatch-alist) 'avy-action-copy
      (alist-get ?W avy-dispatch-alist) 'avy-action-copy-whole-line)

;; Copy String

(defun bounds-of-double-quoted-string-at-point ()
  "Find the bounds of a double-quoted string at point."
  (save-excursion
    (let ((start nil)
          (end nil))
      ;; Search backward for opening quote
      (when (or (looking-at "\"")
                (search-backward "\"" (line-beginning-position) t))
        (setq start (point))
        ;; Search forward for closing quote
        (forward-char)
        (when (search-forward "\"" (line-end-position) t)
          (setq end (point))))
      (when (and start end)
        (cons start end)))))

(defun avy-action-copy-string (pt)
  (save-excursion
    (goto-char pt)
    (let ((bounds (bounds-of-double-quoted-string-at-point)))
      (when bounds
        (copy-region-as-kill (car bounds) (cdr bounds)))))
  (select-window
   (cdr
    (ring-ref avy-ring 0)))
  t)

(setf (alist-get ?c  avy-dispatch-alist) 'avy-action-copy-string)

;; Yank text
(defun avy-action-yank-whole-line (pt)
  (avy-action-copy-whole-line pt)
  (save-excursion (yank))
  t)

(setf (alist-get ?y avy-dispatch-alist) 'avy-action-yank
      (alist-get ?Y avy-dispatch-alist) 'avy-action-yank-whole-line)

;; Transpose/Move text
(defun avy-action-teleport-whole-line (pt)
  (avy-action-kill-whole-line pt)
  (save-excursion (yank)) t)

(setf (alist-get ?t avy-dispatch-alist) 'avy-action-teleport
      (alist-get ?T avy-dispatch-alist) 'avy-action-teleport-whole-line)

;; Mark text
(defun avy-action-mark-to-char (pt)
  (activate-mark)
  (goto-char pt))

(setf (alist-get ?  avy-dispatch-alist) 'avy-action-mark-to-char)

;; Flyspell words
(defun avy-action-flyspell (pt)
  (save-excursion
    (goto-char pt)
    (when (require 'flyspell nil t)
      (flyspell-auto-correct-word)))
  (select-window
   (cdr (ring-ref avy-ring 0)))
  t)

;; Bind to semicolon (flyspell uses C-;)
(setf (alist-get ?\; avy-dispatch-alist) 'avy-action-flyspell)

;; Get Elisp Help
(defun avy-action-helpful (pt)
  (save-excursion
    (goto-char pt)
    (helpful-at-point))
  (select-window
   (cdr (ring-ref avy-ring 0)))
  t)

(setf (alist-get ?H avy-dispatch-alist) 'avy-action-helpful)

;; Embark
(defun avy-action-embark (pt)
  (unwind-protect
      (save-excursion
        (goto-char pt)
        (embark-act))
    (select-window
     (cdr (ring-ref avy-ring 0))))
  t)

(setf (alist-get ?. avy-dispatch-alist) 'avy-action-embark)
