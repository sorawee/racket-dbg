#lang racket/base

(require racket/contract
         "private/client.rkt"
         (except-in "private/memory.rkt"
                    get-object-counts))

(provide
 (struct-out gc-info)
 (contract-out
  [current-client (parameter/c client?)]
  [client? (-> any/c boolean?)]
  [connect (->* ()
                (#:host string?
                 #:port (integer-in 0 65535))
                client?)]
  [connected? (client-> boolean?)]
  [reconnect! (client-> void?)]
  [disconnect! (client-> void?)]
  [subscribe (case-client-> symbol? void?)]
  [unsubscribe (case-client-> symbol? void?)]
  [async-evt (client-> evt?)]
  [get-info (client-> hash?)]
  [get-memory-use (client-> exact-positive-integer?)]
  [get-object-counts (client-> (listof (cons/c string? (cons/c exact-nonnegative-integer?
                                                               exact-nonnegative-integer?))))]
  [get-struct-reference-graph (client-> string? hash?)]
  [get-type-reference-graph (client-> string? hash?)]
  [start-profile (->* () (client? exact-nonnegative-integer? boolean?) void?)]
  [stop-profile (client-> any/c)]
  [get-profile (client-> any/c)]))

(define-syntax-rule (client-> arg/c ... res/c)
  (->* (arg/c ...) (client?) res/c))

(define-syntax-rule (case-client-> arg/c ... res/c)
  (case->
   (-> arg/c ... res/c)
   (-> client? arg/c ... res/c)))
