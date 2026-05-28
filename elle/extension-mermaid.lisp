(elle/epoch 10)
## Mermaid extension backed by the Elle mmdflux plugin.

(defn emacs-hypervisor-mermaid-extension-module [extensions]
  (defn extension-error-payload [kind message &named renderer]
    (let [base {:ok false :error kind :message message}]
      (if renderer (put base :renderer renderer) base)))

  (defn protect-message [result fallback]
    (case (type-of result)
      :struct (or (get result :message) (string result))
      :@struct (or (get result :message) (string result))
      :string result
      (or fallback (string result))))

  (defn mmdflux-plugin-spec []
    (or (sys/env "EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_MMDFLUX_PATH") "plugin/mmdflux"))

  (defn load-mmdflux []
    (let* [spec (mmdflux-plugin-spec)
           [ok? plugin] (protect (import spec))]
      (if ok? plugin nil)))

  (defn normalize-render-style [style]
    (case (string (or style 'ascii))
      "svg" 'svg
      "ascii" 'ascii
      nil))

  (defn render-ascii [mmdflux source args]
    (let* [viewport (extensions:extension-call-field args :viewport)
           max-width (extensions:extension-call-field viewport :width)
           opts (render-options args)
           fit-opts (put (put opts :max-width max-width) :padding 1)
           [ok? ascii] (protect (mmdflux:render-ascii-fit source fit-opts))]
      (if ok?
        {:ok true :kind :text :mime "text/plain" :text ascii :renderer :mmdflux}
        (extension-error-payload :render-failed (protect-message ascii "mmdflux ASCII render failed") :renderer :mmdflux))))

  (defn render-options [args]
    (or (extensions:extension-call-field args :options) {}))

  (defn render-svg [mmdflux source args]
    (let [[ok? svg] (protect (mmdflux:render-svg source (render-options args)))]
      (if ok?
        {:ok true :kind :image :mime "image/svg+xml" :svg svg :renderer :mmdflux}
        (extension-error-payload :render-failed (protect-message svg "mmdflux SVG render failed") :renderer :mmdflux))))

  (defn render [mmdflux args]
    (let [source (extensions:extension-call-field args :source)
          style (normalize-render-style (extensions:extension-call-field args :style))]
      (if (not (= (type-of source) :string))
        (extension-error-payload :invalid-request "mermaid/render requires :source string" :renderer :mmdflux)
        (case style
          'ascii (render-ascii mmdflux source args)
          'svg (render-svg mmdflux source args)
          (extension-error-payload :invalid-request "mermaid/render :style must be :ascii or :svg" :renderer :mmdflux)))))

  (defn make-handler [_settings]
    (let [mmdflux (load-mmdflux)]
      (if mmdflux
        {:render (fn [args] (render mmdflux args))}
        nil)))

  (defn register [settings handlers]
    (let [handler (make-handler settings)]
      (if handler (put handlers :mermaid handler) handlers)))

  {:register register :render render})
