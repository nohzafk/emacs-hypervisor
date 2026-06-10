(elle/epoch 10)
## Shared `sexp-rpc` protocol helpers.

(defn emacs-hypervisor-protocol-module []
  (def sync ((import "std/sync")))
  (def protocol-name :sexp-rpc)
  (def protocol-version 1)

  (defn make-mailbox []
    @{:arrival () :events {} :monitor (sync:make-monitor) :other () :reader-started false :responses {}})

  (defn mailbox-arrival [mailbox]
    (get mailbox :arrival ()))

  (defn set-mailbox-arrival [mailbox arrival]
    (put mailbox :arrival arrival))

  (defn mailbox-events [mailbox]
    (get mailbox :events {}))

  (defn set-mailbox-events [mailbox events]
    (put mailbox :events events))

  (defn mailbox-other [mailbox]
    (get mailbox :other ()))

  (defn mailbox-monitor [mailbox]
    (get mailbox :monitor))

  (defn set-mailbox-other [mailbox other]
    (put mailbox :other other))

  (defn mailbox-reader-started? [mailbox]
    (get mailbox :reader-started false))

  (defn set-mailbox-reader-started [mailbox started?]
    (put mailbox :reader-started started?))

  (defn mailbox-responses [mailbox]
    (get mailbox :responses {}))

  (defn set-mailbox-responses [mailbox responses]
    (put mailbox :responses responses))

  (defn sexp-sequence-string [values]
    (match values
      () ""
      (item & rest)
        (let [head (sexp-string item)
              tail (sexp-sequence-string rest)]
          (if (= tail "") head (string head " " tail)))
      _ ""))

  (defn sexp-string [value]
    (let [value (if (= (type-of value) :syntax) (syntax->datum value) value)]
      (if (nil? value)
        "nil"
        (case (type-of value)
          :list (string "(" (sexp-sequence-string value) ")")
          :array
            (string "[" (sexp-sequence-string (->list value)) "]")
          :@array
            (string "[" (sexp-sequence-string (->list value)) "]")
          :string (json/serialize value)
          :integer (string value)
          :float (string value)
          :boolean (if value "true" "false")
          :keyword (string ":" (string value))
          :symbol (string value)
          (error (string "cannot serialize value of type " (string (type-of value)) " as an S-expression"))))))

  (defn send-message [message]
    (println (sexp-string (to-wire message))))

  (defn plist-get [xs key]
    (match xs
      () nil
      (k v & rest) (if (= k key) v (plist-get rest key))
      _ nil))

  (defn plist-like? [xs]
    (match xs
      () true
      (k _ & rest)
        (and (= (type-of k) :keyword) (plist-like? rest))
      _ false))

  (defn from-wire-plist [xs]
    (match xs
      () {}
      (k v & rest) (put (from-wire-plist rest) k (from-wire v))
      _ {}))

  (defn raw-wire-field? [raw-keys key]
    (any? (fn [raw-key] (= raw-key key)) raw-keys))

  (defn from-wire-plist-preserving [xs raw-keys]
    (match xs
      () {}
      (k v & rest)
        (put (from-wire-plist-preserving rest raw-keys) k (if (raw-wire-field? raw-keys k) v (from-wire v)))
      _ {}))

  (defn from-wire [value]
    (case (type-of value)
      :list (if (plist-like? value) (from-wire-plist value) (map from-wire value))
      :array (->array (map from-wire value))
      :@array
        (thaw (->array (map from-wire value)))
      :string (string "" value)
      value))

  (defn wire-field [value key]
    (case (type-of value)
      :struct (get value key)
      :@struct (get value key)
      (plist-get value key)))

  (defn from-wire-unit-entry [entry]
    (case (type-of entry)
      :list (from-wire-plist-preserving entry (list :body))
      entry))

  (defn from-wire-session-data [payload]
    {:packages (map from-wire (or (wire-field payload :packages) ()))
     :units (map from-wire-unit-entry (or (wire-field payload :units) ()))
     :env (map from-wire (or (wire-field payload :env) ()))
     :extensions (from-wire (wire-field payload :extensions))
     :lint (map from-wire (or (wire-field payload :lint) ()))})

  (defn to-wire-struct [value]
    (reduce (fn [fields key] (append fields (list key (to-wire (get value key))))) () (keys value)))

  (defn to-wire [value]
    (case (type-of value)
      :struct (to-wire-struct value)
      :@struct (to-wire-struct value)
      :list (map to-wire value)
      :array (->array (map to-wire value))
      :@array
        (thaw (->array (map to-wire value)))
      value))

  (defn message-body [message]
    (rest message))

  (defn rpc-message? [message]
    (and (= (first message) :rpc) (= (plist-get (message-body message) :protocol) protocol-name)
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
    (append `(:rpc :protocol ,protocol-name :version ,protocol-version :kind ,kind) fields))

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

  (defn send-envelope [message]
    (send-message message))

  (defn send-request [id op payload]
    (send-envelope (make-request id op payload)))

  (defn send-response [id payload]
    (send-envelope (make-response id payload)))

  (defn send-error-response [id error]
    (send-envelope (make-error-response id error)))

  (defn send-event [topic payload]
    (send-envelope (make-event topic payload)))

  (defn send-report [stage phase items]
    (send-envelope (make-report-message stage phase items)))

  (defn read-next-message [label]
    (let [line (port/read-line (*stdin*))]
      (assert line (string "expected " label " from Emacs"))
      (let [message (read line)]
        (assert (rpc-message? message) (string "expected sexp-rpc envelope for " label))
        message)))

  (defn message-route [message]
    (case (message-kind message)
      :response
        `(:response ,(message-id message))
      :event
        `(:event ,(message-topic message))
      '(:other)))

  (defn route-queue [mailbox route]
    (match route
      (:response id) (get (mailbox-responses mailbox) id ())
      (:event topic) (get (mailbox-events mailbox) topic ())
      _ (mailbox-other mailbox)))

  (defn set-route-queue [mailbox route queue]
    (match route
      (:response id)
        (set-mailbox-responses mailbox (put (mailbox-responses mailbox) id queue))
      (:event topic)
        (set-mailbox-events mailbox (put (mailbox-events mailbox) topic queue))
      _ (set-mailbox-other mailbox queue)))

  (defn enqueue-routed-message [mailbox route message]
    (set-route-queue mailbox route (append (route-queue mailbox route) (list message)))
    (set-mailbox-arrival mailbox (append (mailbox-arrival mailbox) (list route))))

  (defn route-message [mailbox message]
    (enqueue-routed-message mailbox (message-route message) message))

  (defn remove-first-route [routes expected]
    (match routes
      () ()
      (route & rest)
        (if (= route expected) rest (pair route (remove-first-route rest expected)))
      _ ()))

  (defn pop-route-message [mailbox route]
    (let [queue (route-queue mailbox route)]
      (if (empty? queue)
        nil
        (let [message (first queue)]
          (set-route-queue mailbox route (rest queue))
          (set-mailbox-arrival mailbox (remove-first-route (mailbox-arrival mailbox) route))
          message))))

  (defn pop-arrival-message [mailbox]
    (let [arrival (mailbox-arrival mailbox)]
      (if (empty? arrival)
        nil
        (let* [route (first arrival)
               queue (route-queue mailbox route)
               message (first queue)]
          (set-mailbox-arrival mailbox (rest arrival))
          (set-route-queue mailbox route (rest queue))
          message))))

  (defn await-mailbox-message [mailbox label pop-message]
    (let [monitor (mailbox-monitor mailbox)
          message @[nil]]
      (monitor:with (fn []
                      (assert (mailbox-reader-started? mailbox) (string "mailbox reader not started for " label))
                      (while (nil? (message 0))
                        (if-let [next-message (pop-message)] (put message 0 next-message)
                                (begin
                                  (monitor:wait)
                                  (assert (mailbox-reader-started? mailbox)
                                          (string "mailbox reader not started for " label)))))
                      (message 0)))))

  (defn run-mailbox-reader [mailbox]
    (let [monitor (mailbox-monitor mailbox)]
      (while true
        (let [message (read-next-message "rpc message")]
          (monitor:with (fn []
                          (route-message mailbox message)
                          (monitor:broadcast)))))))

  (defn with-mailbox-reader [mailbox body]
    (ev/scope (fn [spawn]
                (set-mailbox-reader-started mailbox true)
                (spawn (fn [] (run-mailbox-reader mailbox)))
                (body))))

  (defn read-message [mailbox label]
    (await-mailbox-message mailbox label (fn [] (pop-arrival-message mailbox))))

  (defn await-route-message [mailbox route label]
    (await-mailbox-message mailbox label (fn [] (pop-route-message mailbox route))))

  (defn expect-message-kind [message expected label]
    (assert (= (message-kind message) expected) (string "expected " label)))

  (defn expect-request-op [message expected label]
    (expect-message-kind message :request label)
    (assert (= (message-op message) expected) (string "expected request " label)))

  (defn expect-event-topic [message expected label]
    (expect-message-kind message :event label)
    (assert (= (message-topic message) expected) (string "expected event " label)))

  (defn await-response [mailbox id]
    (await-route-message mailbox `(:response ,id) ":response"))

  (defn await-event-topic [mailbox topic label]
    (await-route-message mailbox `(:event ,topic) label))

  {:await-event-topic await-event-topic
   :await-response await-response
   :expect-event-topic expect-event-topic
   :expect-message-kind expect-message-kind
   :expect-request-op expect-request-op
   :from-wire from-wire
   :from-wire-session-data from-wire-session-data
   :make-mailbox make-mailbox
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
   :sexp-string sexp-string
   :to-wire to-wire
   :with-mailbox-reader with-mailbox-reader})
