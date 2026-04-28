;;; emacs-hypervisor-effect-kind-keybinding.el --- Keybinding effect support -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-registry)

(defvar emacs-hypervisor-effect-kind-keybinding--states
  (make-hash-table :test 'equal)
  "Session-local keybinding state keyed by effect state id.")

(defvar emacs-hypervisor-effect-kind-keybinding--state-counter 0
  "Counter used to assign keybinding state ids.")

(defun emacs-hypervisor-effect-kind-keybinding--reset-states ()
  (clrhash emacs-hypervisor-effect-kind-keybinding--states)
  (setq emacs-hypervisor-effect-kind-keybinding--state-counter 0))

(defun emacs-hypervisor-effect-kind-keybinding-form-p (form)
  (and (consp form)
       (memq (car form)
             '(keymap-set define-key global-set-key keymap-global-set))
       (pcase (car form)
         ((or 'keymap-set 'define-key) (= (length form) 4))
         ((or 'global-set-key 'keymap-global-set) (= (length form) 3))
         (_ nil))))

(defun emacs-hypervisor-effect-kind-keybinding--parts (form)
  "Return (OPERATOR MAP KEY DEFINITION) for keybinding FORM."
  (pcase (car form)
    ('keymap-set
     (list 'keymap-set (nth 1 form) (nth 2 form) (nth 3 form)))
    ('define-key
     (list 'define-key (nth 1 form) (nth 2 form) (nth 3 form)))
    ('global-set-key
     (list 'global-set-key 'global-map (nth 1 form) (nth 2 form)))
    ('keymap-global-set
     (list 'keymap-global-set 'global-map (nth 1 form) (nth 2 form)))))

(defun emacs-hypervisor-effect-kind-keybinding-rewrite-form
    (unit-name form)
  (if (emacs-hypervisor-effect-kind-keybinding-form-p form)
      (cl-destructuring-bind (operator map key definition)
          (emacs-hypervisor-effect-kind-keybinding--parts form)
        (list
         'emacs-hypervisor-register-keybinding-effect
         :unit unit-name
         :operator (list 'quote operator)
         :map map
         :map-form (list 'quote map)
         :key key
         :definition definition
         :source (list 'quote
                       (emacs-hypervisor-effect-aware-reload-source-plist
                        form))))
    form))

(defun emacs-hypervisor-effect-kind-keybinding--descriptor-operator-p
    (operator)
  (memq operator '(keymap-set keymap-global-set)))

(defun emacs-hypervisor-effect-kind-keybinding--key-sequence
    (operator key)
  (if (and (emacs-hypervisor-effect-kind-keybinding--descriptor-operator-p
            operator)
           (stringp key))
      (kbd key)
    key))

(defun emacs-hypervisor-effect-kind-keybinding--normalize-lookup
    (binding)
  (if (integerp binding) nil binding))

(defun emacs-hypervisor-effect-kind-keybinding--lookup
    (map key operator)
  (emacs-hypervisor-effect-kind-keybinding--normalize-lookup
   (if (and (emacs-hypervisor-effect-kind-keybinding--descriptor-operator-p
             operator)
            (stringp key)
            (fboundp 'keymap-lookup))
       (keymap-lookup map key)
     (lookup-key
      map
      (emacs-hypervisor-effect-kind-keybinding--key-sequence
       operator
       key)))))

(defun emacs-hypervisor-effect-kind-keybinding--set
    (map key definition operator)
  (if (and (emacs-hypervisor-effect-kind-keybinding--descriptor-operator-p
            operator)
           (stringp key)
           (fboundp 'keymap-set))
      (keymap-set map key definition)
    (define-key
     map
     (emacs-hypervisor-effect-kind-keybinding--key-sequence
      operator
      key)
     definition)))

(defun emacs-hypervisor-effect-kind-keybinding--unset
    (map key operator)
  (define-key
   map
   (emacs-hypervisor-effect-kind-keybinding--key-sequence operator key)
   nil))

(defun emacs-hypervisor-effect-kind-keybinding--next-state-id
    (unit key)
  (setq emacs-hypervisor-effect-kind-keybinding--state-counter
        (+ emacs-hypervisor-effect-kind-keybinding--state-counter 1))
  (format
   "%s/keybinding/%s/%d"
   (or unit "anonymous-unit")
   (emacs-hypervisor-effect-registry--safe-name-component key)
   emacs-hypervisor-effect-kind-keybinding--state-counter))

(defun emacs-hypervisor-effect-kind-keybinding--retract
    (state-id)
  "Remove keybinding effect STATE-ID if the binding has not diverged."
  (let ((state
         (gethash state-id
                  emacs-hypervisor-effect-kind-keybinding--states)))
    (unless state
      (error "No keybinding state for effect %s" state-id))
    (let* ((map (plist-get state :map))
           (key (plist-get state :key))
           (operator (plist-get state :operator))
           (definition (plist-get state :definition))
           (current
            (emacs-hypervisor-effect-kind-keybinding--lookup
             map
             key
             operator)))
      (unwind-protect
          (if (equal current definition)
              (progn
                (emacs-hypervisor-effect-kind-keybinding--unset
                 map
                 key
                 operator)
                t)
            (display-warning
             'emacs-hypervisor
             (format
              "Skipped keybinding cleanup for %s in %s; current binding changed outside Hypervisor"
              key
              (or (plist-get state :unit) "anonymous-unit"))
             :warning)
            nil)
        (remhash
         state-id
         emacs-hypervisor-effect-kind-keybinding--states)))))

;;;###autoload
(cl-defun emacs-hypervisor-register-keybinding-effect
    (&key unit operator map map-form key definition source)
  "Install and record a keybinding effect."
  (let* ((state-id
          (emacs-hypervisor-effect-kind-keybinding--next-state-id
           unit
           key))
         (target (list :map map-form :key key))
         (body-hash
          (emacs-hypervisor-effect-registry--hash-value
           (list :operator operator
                 :map map-form
                 :key key
                 :definition definition
                 :source source))))
    (condition-case err
        (progn
          (emacs-hypervisor-effect-kind-keybinding--set
           map
           key
           definition
           operator)
          (puthash
           state-id
           (list :unit unit
                 :operator operator
                 :map map
                 :map-form map-form
                 :key key
                 :definition definition)
           emacs-hypervisor-effect-kind-keybinding--states)
          (emacs-hypervisor-effect-registry-record
           (list
            :unit unit
            :kind :keybinding
            :target target
            :function definition
            :source source
            :apply (or (plist-get source :form)
                       (list operator map-form key definition))
            :retract
            (list
             'emacs-hypervisor-effect-kind-keybinding--retract
             state-id)
            :body-hash body-hash
            :metadata
            (list :operator operator
                  :map map-form
                  :key key
                  :state-id state-id))))
      (error
       (remhash state-id
                emacs-hypervisor-effect-kind-keybinding--states)
       (signal (car err) (cdr err))))))

(emacs-hypervisor-effect-aware-reload-register-effect-spec
 (list :kind :keybinding
       :operator 'keymap-set
       :predicate #'emacs-hypervisor-effect-kind-keybinding-form-p
       :rewrite #'emacs-hypervisor-effect-kind-keybinding-rewrite-form))

(emacs-hypervisor-effect-aware-reload-register-effect-spec
 (list :kind :keybinding
       :operator 'define-key
       :predicate #'emacs-hypervisor-effect-kind-keybinding-form-p
       :rewrite #'emacs-hypervisor-effect-kind-keybinding-rewrite-form))

(emacs-hypervisor-effect-aware-reload-register-effect-spec
 (list :kind :keybinding
       :operator 'global-set-key
       :predicate #'emacs-hypervisor-effect-kind-keybinding-form-p
       :rewrite #'emacs-hypervisor-effect-kind-keybinding-rewrite-form))

(emacs-hypervisor-effect-aware-reload-register-effect-spec
 (list :kind :keybinding
       :operator 'keymap-global-set
       :predicate #'emacs-hypervisor-effect-kind-keybinding-form-p
       :rewrite #'emacs-hypervisor-effect-kind-keybinding-rewrite-form))

(add-hook 'emacs-hypervisor-effect-registry-reset-hook
          #'emacs-hypervisor-effect-kind-keybinding--reset-states)

(provide 'emacs-hypervisor-effect-kind-keybinding)
