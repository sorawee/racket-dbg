#lang racket/base

(require debugging/client
         plot
         racket/class
         racket/format
         racket/gui/easy
         racket/gui/easy/operator
         racket/list
         racket/match)

(provide
 start-ui)

;; state ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct memory-tick (ts amount)
  #:transparent)

(struct gc-tick (ts mode amount duration)
  #:transparent)

(struct state
  (history
   memory-use
   memory-use/max
   memory-use/time
   gc-duration/total
   gc-duration/max
   gcs/time)
  #:transparent)

(define (make-state)
  (state 100 0 0 null 0 0 null))

(define (set-memory-use s amt)
  (struct-copy state s
               [memory-use amt]
               [memory-use/max (max (state-memory-use/max s) amt)]))

(define (add-gc-tick s ts i)
  (define hist (state-history s))
  (define mode (gc-info-mode i))
  (define amt (gc-info-post-amount i))
  (define duration
    (- (gc-info-end-time i)
       (gc-info-start-time i)))
  (struct-copy
   state s
   [memory-use amt]
   [memory-use/max (max
                    (state-memory-use/max s)
                    (gc-info-pre-amount i))]
   [memory-use/time (keep-right
                     (append
                      (state-memory-use/time s)
                      `(,(memory-tick ts amt)))
                     hist)]
   [gc-duration/total (+ (state-gc-duration/total s) duration)]
   [gc-duration/max (max (state-gc-duration/max s) duration)]
   [gcs/time (keep-right
              (append
               (state-gcs/time s)
               `(,(gc-tick ts mode amt duration)))
              hist)]))

(define (start-async-handler @state evt)
  (thread
   (lambda ()
     (let loop ()
       (sync
        (handle-evt
         evt
         (λ (topic&data)
           (match topic&data
             [`(gc ,ts ,info)
              (@state . <~ . (λ (s)
                               (add-gc-tick s ts info)))
              (loop)]

             [_
              (loop)]))))))))

;; components ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-syntax-rule (defer e0 e ...)
  (thread (λ () e0 e ...)))

(define ((make-window-mixin c) %)
  (class %
    (super-new)
    (define/augment (on-close)
      (disconnect c))))

(define (labeled label v)
  (hpanel
   #:stretch '(#t #f)
   (hpanel
    #:min-size '(130 #f)
    #:stretch '(#f #t)
    (text label))
   v))

(define (info-tab c)
  (define info (get-info c))
  (vpanel
   #:alignment '(left top)
   (labeled "Operating system:" (text (~a (hash-ref info 'os*))))
   (labeled "Virtual machine:" (text (~a (hash-ref info 'vm))))
   (labeled "Architecture:" (text (~a (hash-ref info 'arch))))
   (labeled "Version:" (text (hash-ref info 'version)))))

(define (charts-tab @state action)
  (define/obs @have-gc-data?
    (@state . ~> . (compose1 not null? state-memory-use/time)))
  (define/obs @hist
    (state-history (obs-peek @state)))
  (vpanel
   (labeled "Memory use:" (text (@state . ~> . (compose1 ~size state-memory-use))))
   (labeled "Total GC time:" (text (@state . ~> . (compose1 ~ms state-gc-duration/total))))
   (labeled "Longest GC pause:" (text (@state . ~> . (compose1 ~ms state-gc-duration/max))))
   (vpanel
    (hpanel
     #:stretch '(#t #f)
     (labeled
      "Max history:"
      (input
       #:stretch '(#f #f)
       #:min-size '(240 #f)
       (@hist . ~> . number->string)
       (λ (event text)
         (case event
           [(return)
            (define hist (string->number text))
            (when hist
              (@hist . := . hist)
              (action `(commit-history ,hist)))])))))
    (cond-view
     [@have-gc-data?
      (hpanel
       (plot-canvas @state plot-memory-usage)
       (plot-canvas @state plot-gc-pauses))]

     [else
      (text "No GC data.")]))))

(define (memory-tab c)
  (define/obs @filter-re (regexp ""))
  (define/obs @counts #f)
  (define (reload)
    (defer (@counts . := . (get-object-counts c))))
  (define (compute-total-bytes counts)
    (for/sum ([c (in-list (or counts null))])
      (cddr c)))

  (reload)
  (vpanel
   (hpanel
    #:stretch '(#t #f)
    (vpanel
     #:alignment '(left center)
     (labeled
      "Total size: "
      (text (@counts . ~> . (compose1 ~size compute-total-bytes)))))
    (hpanel
     #:alignment '(right center)
     (text "Filter:")
     (input "" (λ (_ text)
                 (@filter-re . := . (regexp text)))))
    (button "Reload" reload))
   (cond-view
    [@counts
     (table
      '("Kind" "Count" "Size")
      #:column-widths `((0 320))
      (obs-combine
       (λ (maybe-counts filter-re)
         (for/vector ([c (in-list (or maybe-counts null))]
                      #:when (regexp-match? filter-re (car c)))
           c))
       @counts @filter-re)
      #:entry->row (λ (entry)
                     (vector
                      (car entry)
                      (~a (cadr entry))
                      (~size (cddr entry)))))]
    [else
     (text "Loading...")])))

(define (start-ui c)
  (define/obs @tab 'info)
  (define/obs @state
    (set-memory-use
     (make-state)
     (get-memory-use c)))
  (define/obs @state/throttled
    (obs-throttle
     #:duration 250
     @state))
  (start-async-handler @state (async-evt c))
  (subscribe c 'gc)
  (render
   (window
    #:title "Remote Debugger"
    #:size '(600 400)
    #:mixin (make-window-mixin c)
    (let ([the-tabs '(info charts memory)])
      (tabs
       (map (compose1 string-titlecase symbol->string) the-tabs)
       (λ (event _choices index)
         (case event
           [(select)
            (@tab . := . (list-ref the-tabs index))]))
       (case-view
        @tab
        [(info)
         (info-tab c)]

        [(charts)
         (charts-tab
          @state/throttled
          (match-lambda
            [`(commit-history ,hist)
             (@state . <~ . (λ (s)
                              (struct-copy state s [history hist])))]))]

        [(memory)
         (memory-tab c)]

        [else
         (hpanel)]))))))

(define (plot-memory-usage s w h)
  (parameterize ([plot-title "Memory Use"]
                 [plot-x-label "Time"]
                 [plot-y-label "MiB"]
                 [plot-x-ticks (date-ticks)]
                 [plot-pen-color-map 'tab20c])
    (define max-memory (->MiB (state-memory-use/max s)))
    (define memory-use
      (for/list ([t (in-list (state-memory-use/time s))])
        `(,(memory-tick-ts t)
          ,(->MiB (memory-tick-amount t)))))
    (define major-gcs
      (for/list ([t (in-list (state-gcs/time s))]
                 #:when (eq? 'major (gc-tick-mode t)))
        `(,(gc-tick-ts t)
          ,(->MiB (gc-tick-amount t)))))

    (plot-snip
     #:width w
     #:height h
     #:y-min 0
     #:y-max (* 1.10 max-memory)
     (list
      (hrule
       #:label "Max Memory"
       #:style 'long-dash
       max-memory)
      (area
       #:label "Memory"
       #:color 4
       #:line1-color 4
       #:line1-style 'transparent
       #:line2-color 4
       memory-use)
      (points
       #:label "Major GC"
       #:sym 'times
       #:color 4
       #:size 12
       major-gcs)))))

(define (plot-gc-pauses s w h)
  (parameterize ([plot-title "GC Pauses"]
                 [plot-x-label "Time"]
                 [plot-y-label "Duration (ms)"]
                 [plot-x-ticks (date-ticks)]
                 [plot-pen-color-map 'tab20c])
    (define minor-gcs
      (for/list ([t (in-list (state-gcs/time s))]
                 #:when (eq? 'minor (gc-tick-mode t)))
        `(,(gc-tick-ts t)
          ,(gc-tick-duration t))))
    (define major-gcs
      (for/list ([t (in-list (state-gcs/time s))]
                 #:when (eq? 'major (gc-tick-mode t)))
        `(,(gc-tick-ts t)
          ,(gc-tick-duration t))))
    (plot-snip
     #:width w
     #:height h
     #:y-min 0
     #:y-max (* 1.10
                (max
                 (if (null? minor-gcs) 0 (apply max (map cadr minor-gcs)))
                 (if (null? major-gcs) 0 (apply max (map cadr major-gcs)))))
     (list
      (points #:label "Major GC" #:color 4 major-gcs)
      (points #:label "Minor GC" #:color 1 minor-gcs)))))

(define (plot-canvas @data make-plot-snip)
  (canvas
   @data
   (λ (dc data)
     (define-values (w h)
       (send dc get-size))
     (define snip
       (make-plot-snip data w h))
     (define bmp
       (send snip get-bitmap))
     (send dc draw-bitmap bmp 0 0))))

(define area
  (make-keyword-procedure
   (lambda (kws kw-args vs . args)
     (keyword-apply
      lines-interval
      kws kw-args
      (for/list ([t (in-list vs)])
        `(,(car t) 0))
      vs
      args))))


;; helpers ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (keep-right xs n)
  (if (> (length xs) n)
      (take-right xs n)
      xs))

(define (->MiB v)
  (/ v 1024 1024))

(define (~ms v)
  (format "~a ms" v))

(define (~size bs)
  (define-values (n suffix)
    (let loop ([n bs]
               [suffix "B"]
               [suffixes '("KiB" "MiB" "GiB" "TiB")])
      (if (or (empty? suffixes)
              (< n 1024))
          (values n suffix)
          (loop (/ n 1024.0)
                (car suffixes)
                (cdr suffixes)))))
  (define n-str
    (if (integer? n)
        (~r n)
        (~r #:precision '(= 2) n)))
  (~a n-str suffix))