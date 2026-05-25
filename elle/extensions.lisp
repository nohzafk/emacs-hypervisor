(elle/epoch 10)
## Extension registry and request dispatch.

(defn emacs-hypervisor-extensions-module [protocol]
  (defn extension-call-field [payload key]
    (case (type-of payload)
      :struct (get payload key)
      :@struct (get payload key)
      (protocol:plist-get payload key)))

  (defn make-registry [settings handlers]
    {:settings settings :handlers handlers})

  (defn extension-names [settings]
    (filter (fn [name] (not (= name ""))) (map string/trim (string/split (or (get settings :extensions) "") ","))))

  (defn unsupported-extensions [settings handlers]
    (filter (fn [name] (nil? (get handlers (keyword name)))) (extension-names settings)))

  (defn extension-unavailable [id name]
    (protocol:send-error-response id (string "extension unavailable: " name)))

  (defn method-unavailable [id extension method]
    (protocol:send-error-response id (string "extension method unavailable: " extension "/" method)))

  (defn handler-method [handler method]
    (case (type-of handler)
      :struct (get handler method)
      :@struct (get handler method)
      nil))

  (defn dispatch-extension-call [registry message]
    (let [id (protocol:message-id message)
          payload (protocol:from-wire (protocol:message-payload message))
          extension (extension-call-field payload :extension)
          method (extension-call-field payload :method)
          args (or (extension-call-field payload :args) {})
          handler (get (get registry :handlers) extension)
          method-fn (handler-method handler method)]
      (if (nil? handler)
        (extension-unavailable id extension)
        (if (nil? method-fn) (method-unavailable id extension method) (protocol:send-response id (method-fn args))))))

  (defn handle-extension-message [registry message]
    (case (protocol:message-kind message)
      :request
        (case (protocol:message-op message)
          :extension-call (dispatch-extension-call registry message)
          (protocol:send-error-response (protocol:message-id message)
                                        (string "unknown extension actor request: " (protocol:message-op message))))
      :event nil
      :response nil
      nil))

  (defn run-extension-actor [mailbox registry]
    (while true (handle-extension-message registry (protocol:read-message mailbox "extension actor message"))))

  {:make-registry make-registry
   :extension-names extension-names
   :unsupported-extensions unsupported-extensions
   :dispatch-extension-call dispatch-extension-call
   :extension-call-field extension-call-field
   :handle-extension-message handle-extension-message
   :run-extension-actor run-extension-actor})
