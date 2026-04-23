(defun my/shorten-path-for-title (path)
  "Shorten a file PATH to be displayed in the frame title.

Only the last directory's name is fully displayed; upper-layer directories are
represented by their first letters."
  (let* ((components (split-string (or path "") "/" t))
         (filename (or (car (last components)) ""))
         (lastdir (if (> (length components) 1) (nth (- (length components) 2) components) ""))
         (dirs (butlast components 2))
         (shortened-dirs (mapcar (lambda (dir) (substring dir 0 1)) dirs)))
    (concat (string-join shortened-dirs "/")
            (if shortened-dirs "/")
            lastdir
            "/"
            filename)))

(defun my/xah-toggle-letter-case ()
  "Toggle the letter case of current word or text selection.
Always cycle in this order: Init Caps, ALL CAPS, all lower.

URL `http://ergoemacs.org/emacs/modernization_upcase-word.html'
Version 2016-01-08"
  (interactive)
  (let (
        (deactivate-mark nil)
        ξp1 ξp2)
    (if (use-region-p)
        (setq ξp1 (region-beginning)
              ξp2 (region-end))
      (save-excursion
        (skip-chars-backward "[:alnum:]")
        (setq ξp1 (point))
        (skip-chars-forward "[:alnum:]")
        (setq ξp2 (point))))
    (when (not (eq last-command this-command))
      (put this-command 'state 0))
    (cond
     ((equal 0 (get this-command 'state))
      (upcase-initials-region ξp1 ξp2)
      (put this-command 'state 1))
     ((equal 1  (get this-command 'state))
      (upcase-region ξp1 ξp2)
      (put this-command 'state 2))
     ((equal 2 (get this-command 'state))
      (downcase-region ξp1 ξp2)
      (put this-command 'state 0)))))

(defun my/exchange-point-and-mark-no-activate ()
  "Identical to \\[exchange-point-and-mark] but will not activate the region."
  (interactive)
  (exchange-point-and-mark)
  (deactivate-mark nil))
