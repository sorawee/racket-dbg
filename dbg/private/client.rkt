#lang racket/base

(require racket/match
         racket/tcp
         "common.rkt")

(provide
 client?
 connect
 disconnect
 subscribe
 unsubscribe
 async-evt
 get-info
 get-memory-use)

(struct client (async-ch manager-thd))

(struct Cmd (id res-ch nack-evt))
(struct Rep Cmd (response))

(define (connect #:host [host "127.0.0.1"]
                 #:port [port 9011])
  (define-values (in out)
    (tcp-connect host port))
  (define async-ch (make-channel))
  (define manager-thd
    (thread/suspend-to-kill
     (lambda ()
       (let loop ([seq 0] [cmds null])
         (with-handlers ([exn:fail:network?
                          (λ (e)
                            (log-error "connection error: ~a" (exn-message e)))])
           (apply
            sync
            (handle-evt
             (thread-receive-evt)
             (λ (_)
               (match (thread-receive)
                 [`(,name ,args ... ,res-ch ,nack-evt)
                  (define cmd (Cmd seq res-ch nack-evt))
                  (write/flush `(,name ,seq ,@args) out)
                  (loop (add1 seq) (cons cmd cmds))])))

            (handle-evt
             in
             (lambda (_)
               (define data (read in))
               (define-values (id response)
                 (match data
                   [(? eof-object?)
                    (values #f #f)]

                   [`(async ,topic ,ts ,data)
                    (values 'async `(,topic ,ts ,data))]

                   [`(error ,id ,message)
                    (values id (exn:fail message (current-continuation-marks)))]

                   [`(,cmd ,id ,args ...)
                    (values id `(,cmd ,@args))]

                   [`(error ,message)
                    (values #f message)]))

               (cond
                 [(and id (eq? id 'async))
                  (sync/timeout 0 (channel-put-evt async-ch response))
                  (loop seq cmds)]

                 [(and id (findf
                           (λ (r)
                             (equal? (Cmd-id r) id))
                           cmds))
                  => (λ (req)
                       (define rep
                         (Rep (Cmd-id req)
                              (Cmd-res-ch req)
                              (Cmd-nack-evt req)
                              response))
                       (loop seq (cons rep (remq req cmds))))]

                 [else
                  (log-warning "orphan response: ~e" data)
                  (loop seq cmds)])))

            (append
             (for/list ([cmd (in-list cmds)])
               (if (Rep? cmd)
                   (handle-evt
                    (channel-put-evt
                     (Cmd-res-ch cmd)
                     (Rep-response cmd))
                    (λ (_)
                      (loop seq (remq cmd cmds))))
                   never-evt))

             (for/list ([cmd (in-list cmds)])
               (handle-evt
                (Cmd-nack-evt cmd)
                (λ (_)
                  (loop seq (remq cmd cmds))))))))))))
  (client async-ch manager-thd))

(define (send c cmd)
  (define thd (client-manager-thd c))
  (define res-ch (make-channel))
  (nack-guard-evt
   (λ (nack-evt)
     (begin0 res-ch
       (thread-resume thd)
       (thread-send thd `(,@cmd ,res-ch ,nack-evt))))))

(define (disconnect c)
  (void (sync (send c `(disconnect)))))

(define (subscribe c topic)
  (void (sync (send c `(subscribe ,topic)))))

(define (unsubscribe c topic)
  (void (sync (send c `(unsubscribe ,topic)))))

(define (async-evt c)
  (client-async-ch c))

(define (get-info c)
  (cadr (sync (send c `(info)))))

(define (get-memory-use c)
  (cadr (sync (send c `(memory-use)))))