## Shared `sexp-rpc` protocol helpers.

(defn emacs-hypervisor-protocol-module []
  (def protocol-name :sexp-rpc)
  (def protocol-version 1)
  (def @pending-messages ())

  (defn sexp-string [value]
    (let [value (if (= (type-of value) :syntax)
                  (syntax->datum value)
                  value)]
      (case (type-of value)
        :list (string "(" (string/join (map sexp-string value) " ") ")")
        :string (json/serialize value)
        :keyword (string ":" (string value))
        :symbol (string value)
        (string value))))

  (defn send-message [message]
    (println (sexp-string message)))

  (defn plist-get [xs key]
    (if (empty? xs)
      nil
      (if (= (first xs) key)
        (first (rest xs))
        (plist-get (rest (rest xs)) key))))

  (defn message-body [message]
    (rest message))

  (defn rpc-message? [message]
    (and (= (first message) :rpc)
         (= (plist-get (message-body message) :protocol) protocol-name)
         (= (plist-get (message-body message) :version) protocol-version)))

  (defn message-kind [message]
    (plist-get (message-body message) :kind))

  (defn message-id [message]
    (plist-get (message-body message) :id))

  (defn message-op [message]
    (plist-get (message-body message) :op))

  (defn message-topic [message]
    (plist-get (message-body message) :topic))

  (defn message-payload [message]
    (plist-get (message-body message) :payload))

  (defn response-ok? [message]
    (plist-get (message-body message) :ok))

  (defn response-error [message]
    (plist-get (message-body message) :error))

  (defn make-envelope [kind fields]
    (append
     `(:rpc :protocol ,protocol-name :version ,protocol-version :kind ,kind)
     fields))

  (defn make-request [id op payload]
    (make-envelope :request `(:id ,id :op ,op :payload ,payload)))

  (defn make-response [id payload]
    (make-envelope :response `(:id ,id :ok true :payload ,payload)))

  (defn make-error-response [id error]
    (make-envelope :response `(:id ,id :ok false :error ,error)))

  (defn make-event [topic payload]
    (make-envelope :event `(:topic ,topic :payload ,payload)))

  (defn make-report-message [stage phase items]
    (make-event :report `(:stage ,stage :phase ,phase :items ,items)))

  (defn send-request [id op payload]
    (send-message (make-request id op payload)))

  (defn send-response [id payload]
    (send-message (make-response id payload)))

  (defn send-error-response [id error]
    (send-message (make-error-response id error)))

  (defn send-event [topic payload]
    (send-message (make-event topic payload)))

  (defn send-report [stage phase items]
    (send-message (make-report-message stage phase items)))

  (defn read-next-message [label]
    (let [line (port/read-line (*stdin*))]
      (assert line (string "expected " label " from Emacs"))
      (let [message (read line)]
        (assert (rpc-message? message)
                (string "expected sexp-rpc envelope for " label))
        message)))

  (defn pending-result [message pending]
    (list :message message :pending pending))

  (defn take-pending-message [predicate]
    (letrec
        [loop
         (fn [remaining kept]
           (if (empty? remaining)
             (pending-result nil (reverse kept))
             (let [message (first remaining)]
               (if (predicate message)
                 (pending-result
                  message
                  (append (reverse kept) (rest remaining)))
                 (loop (rest remaining) (cons message kept))))))]
      (loop pending-messages ())))

  (defn stash-message [message]
    (assign pending-messages
            (append pending-messages (list message))))

  (defn read-message [label]
    (if (empty? pending-messages)
      (read-next-message label)
      (let [message (first pending-messages)]
        (assign pending-messages (rest pending-messages))
        message)))

  (defn expect-message-kind [message expected label]
    (assert (= (message-kind message) expected)
            (string "expected " label)))

  (defn expect-request-op [message expected label]
    (expect-message-kind message :request label)
    (assert (= (message-op message) expected)
            (string "expected request " label)))

  (defn expect-event-topic [message expected label]
    (expect-message-kind message :event label)
    (assert (= (message-topic message) expected)
            (string "expected event " label)))

  (defn await-matching-message [predicate label]
    (let* [pending (take-pending-message predicate)
           message (plist-get pending :message)]
      (if message
        (begin
          (assign pending-messages (plist-get pending :pending))
          message)
        (let [next-message (read-next-message label)]
          (if (predicate next-message)
            next-message
            (begin
              (stash-message next-message)
              (await-matching-message predicate label)))))))

  (defn await-response [id]
    (await-matching-message
     (fn [message]
       (and (= (message-kind message) :response)
            (= (message-id message) id)))
     ":response"))

  (defn await-event-topic [topic label]
    (await-matching-message
     (fn [message]
       (and (= (message-kind message) :event)
            (= (message-topic message) topic)))
     label))

  {:await-event-topic await-event-topic
   :await-response await-response
   :expect-event-topic expect-event-topic
   :expect-message-kind expect-message-kind
   :expect-request-op expect-request-op
   :make-envelope make-envelope
   :make-error-response make-error-response
   :make-event make-event
   :make-report-message make-report-message
   :make-request make-request
   :make-response make-response
   :message-body message-body
   :message-id message-id
   :message-kind message-kind
   :message-op message-op
   :message-payload message-payload
   :message-topic message-topic
   :plist-get plist-get
   :protocol-name protocol-name
   :protocol-version protocol-version
   :read-message read-message
   :response-error response-error
   :response-ok? response-ok?
   :rpc-message? rpc-message?
   :send-error-response send-error-response
   :send-event send-event
   :send-message send-message
   :send-report send-report
   :send-request send-request
   :send-response send-response
   :sexp-string sexp-string})
