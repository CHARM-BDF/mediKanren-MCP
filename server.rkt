#lang racket

(define port
  (let ((port (getenv "LLM_MEDIKANREN_PORT")))
    (if port
        (string->number port)
        8080)))

(define max-worker-count
  (let ((count (getenv "MAX_WORKER_COUNT")))
    (if count
        (string->number count)
        5)))

(define worker-semaphore (make-semaphore max-worker-count))

(require web-server/servlet)
(require web-server/servlet-env)
(require web-server/http/bindings)
(require web-server/http/json)
(require json)
(require
 "../../../../medikanren2/neo/neo-low-level/query-low-level-multi-db.rkt"
 "../../../../medikanren2/neo/neo-utils/neo-helpers-multi-db.rkt"
"../../../../medikanren2/neo/neo-reasoning/neo-biolink-reasoning.rkt"
 "../utils.rkt"
 racket/format
 racket/list
 racket/match
 racket/set
 racket/pretty
 racket/string
 racket/system)

(require racket/engine)
(define (job-failure x)
  (response/xexpr x))

(define timeout (* 6 1000)) ;; in miliseconds
(define max-waiting (+ timeout 500))

(define (thunk-with-timeout thunk)
  (lambda ()
    (define e (engine (lambda (x) (thunk))))
    (if (engine-run timeout e)
        (engine-result e)
        (begin
          (displayln "timeout")
          (job-failure "timeout")))))

;; taken from mediKanren/medikanren2/server.rkt
(define (work-safely work)
  (define custodian.work (make-custodian))
  (define result
    ;; current-custodian will collect all file handles opened during work
    (parameterize ((current-custodian custodian.work))
      (with-handlers ((exn:fail?
                       (lambda (v)
                         ((error-display-handler) (exn-message v) v)
                         (job-failure (exn-message v))))
                      ((lambda _ #t)
                       (lambda (v)
                         (define message
                           (string-append "unknown error: "
                                          (with-output-to-string (thunk (write v)))))
                         (pretty-write message)
                         (job-failure message))))
                     (call-in-nested-thread work custodian.work))))
  (custodian-shutdown-all custodian.work) ; close all file handles opened during work
  result)
(define (handle-work-safely handle-request)
  (lambda (request)
    (call-with-semaphore
     worker-semaphore
     (thunk-with-timeout
      (lambda ()
        (work-safely (lambda () (handle-request request))))))))
(define w handle-work-safely)

(define (read-json-from-string x)
  (and x (with-input-from-string x (lambda () (read-json)))))

(define (get-sentences-from-attrs attrs)
  (match (hash-ref attrs "attribute_type_id" #f)
    ["biolink:has_supporting_study_result"
     (hash-ref attrs "value_url" #f)]
    ["biolink:supporting_text"
     (hash-ref attrs "value" #f)]
    [_ #f]))

(define (get-sentences props)
  (let ((attrs (read-json-from-string (get-assoc "json_attributes" props))))
    (if attrs
        (filter (lambda (x) x) (map get-sentences-from-attrs attrs))
        (read-json-from-string (get-assoc "publications_info" props)))))

(define (create-entry result)
  (match result
    [`(,subj-curie ,pred ,obj-curie . ,props)
     (list
      subj-curie
      (concept->name subj-curie)
      (or (get-assoc "description" props)
          (get-assoc "predicate_label" props)
          (let ((qp (get-assoc "qualified_predicate" props)))
            (if qp
                (string-append
                 qp
                 " "
                 (or (get-assoc "object_direction_qualifier" props) "")
                 " "
                 (or (get-assoc "object_aspect_qualifier" props) ""))
                #f))
          pred)
      obj-curie
      (concept->name obj-curie)
      (get-sentences props)
      (get-pubs props))]))

(define (cleanup1 result)
  (create-entry result))

(define (cleanup results)
  (map cleanup1 results))

(define robokop-top-bucket (list 5)) ;top/max bucket num of RoboKop KG
(define text-mining-top-bucket (list 5)) ;top/max bucket num of Text Mining KG
(define rtx-kg2-top-bucket (list 7)) ;top/max bucket num of RTX-KG2 KG

; Numbers of the top buckets of RoboKop KG, Text Mining KG, and RTX-KG2 KG (in this order).
; [The higer the bucket number, the higher amount of publications supporting the edge]
(define TOP_BUCKET_NUMBERS (list robokop-top-bucket 
                                 text-mining-top-bucket 
                                 rtx-kg2-top-bucket 
                                 ))
;; Numbers of the top bucket of the RoboKop KG, Text Mining KG, and RTX-KG2 KG.
(define TOP_BUCKET_NUMBERS_AUTOGROW (list (list (get-highest-bucket-number-robokop))
                                          (list (get-highest-bucket-number-text-mining))
                                          (list (get-highest-bucket-number-rtx-kg2))))


(define (start request)
  (server-dispatch request))

(define-values (server-dispatch server-url)
  (dispatch-rules
   (("") (w handle-index-request))
   (("curie2name") (w handle-curie2name-request))
   (("category") (w handle-get-category-request))
   (("query") (w handle-query-request))
   (("query1") (w handle-query1-request))
   (("query0") (w handle-query0-request))
   (else (w handle-index-request))))

(define (handle-index-request request)
  (response/xexpr
   `(html (body
           (div
            (h1 "Welcome to the llm-mediKanren Racket server!")
            (p " The endpoints are:"
               (ul
                (li "curie2name?curie=... " (a ([href "/curie2name?curie=DRUGBANK:DB12411"]) "(example)"))
                (li "query?e1=...&e2=...&e3=... " (a ([href "/query?e1=Known->X&e2=biolink:treats&e3=DRUGBANK:DB12411"]) "(example)"))
                (li "query1?subject=...&predicate=...&object=... " (a ([href "/query1?subject=DRUGBANK:DB12411&predicate=biolink:treats&object="]) "(example)")))))
))))

(define (handle-get-category-request request)
  ;; Call curie->properties to get properties for the given CURIE
  (define params (request-bindings request))
  (define curie (cdr (assoc 'curie params)))
  (define props (curie->properties curie))
  
  ;; Find the category property and return its value
  (response/xexpr
   (let ([cat-pr (assoc "category" props)])
     (if cat-pr (cadr cat-pr) "None"))))

(define (handle-curie2name-request request)
  (define params (request-bindings request))
  (define curie (cdr (assoc 'curie params)))
  (define name (concept->name curie))
  (response/xexpr name))

(define (handle-query-request request)
  (define params (request-bindings request))
  (response/jsexpr
   (generate-response
    (cdr (assoc 'e1 params)) (cdr (assoc 'e2 params)) (cdr (assoc 'e3 params))
    (let ((x (assoc 'autogrow params))) (if x (cdr x) #f)))))

(define (generate-response e1 e2 e3 autogrow?)
  (displayln (format "Handling expression ~a ~a ~a (autogrow?:~a)" e1 e2 e3 autogrow?))
  (flush-output)
  (let ((b2
         (set->list
          (if (string-contains? e2 " ")
              (string-split e2)
              (if (string=? "" e2)
                  all-predicates
                  (get-non-deprecated-mixed-ins-and-descendent-predicates*-in-db
                   (if (string=? "biolink:treats" e2) '("biolink:treats" "biolink:treats_or_applied_or_studied_to_treat") (list e2)))))))
	(b
	 (set->list
          (get-n-descendent-curies*-in-db
           (curies->synonyms-in-db (list e3))
           10000))))
    (let* ((q
            (cond
	     ((string=? "X->Known" e1)
	      (write `(query:X->Known-scored #f ,b2 ,b))
	      (lambda (bucket*) (query:X->Known-scored #f b2 b bucket*)))
	     ((string=? "Known->X" e1)
	      (write `(query:Known->X-scored ,b ,b2 #f))
	      (lambda (bucket*) (query:Known->X-scored b b2 #f bucket*)))
	     (else
	      (displayln (format "error: Unknown: ~a" e1))
	      #f)))
           (r
            (if q
                (if autogrow? (auto-grow q TOP_BUCKET_NUMBERS_AUTOGROW 100) (q TOP_BUCKET_NUMBERS))
                '())))
      (display "RETURNING")
      (set! r (cleanup r))
      (write r)
      (displayln "")
      (flush-output)
      r)))

(define (handle-query0-request request)
  (define params (request-bindings request))
  (response/jsexpr
   (generate-query0-response
    (cdr (assoc 'subject params)) (cdr (assoc 'predicate params)) (cdr (assoc 'object params))
    (let ((x (assoc 'autogrow params))) (if x (cdr x) #f)))))

(define (generate-query0-response subject e2 object autogrow?)
  (displayln (format "Handling query0 expression ~a ~a ~a (autogrow?:~a)" subject e2 object autogrow?))
  (flush-output)
  (let ((b2
         (set->list
          (if (string-contains? e2 " ")
              (string-split e2)
              (if (string=? "" e2)
                  all-predicates
                  (get-non-deprecated-mixed-ins-and-descendent-predicates*-in-db
                   (if (string=? "biolink:treats" e2) '("biolink:treats" "biolink:treats_or_applied_or_studied_to_treat") (list e2)))))))
        (subjects (entity-query-set subject))
        (objects (entity-query-set object)))
    (let* ((q
            (cond
	     ((entity-query-unknown? subject)
	      (write 'query:X->Known-scored)
	      (lambda (bucket*) (query:X->Known-scored subjects b2 (list object) bucket*)))
	     ((entity-query-unknown? object)
	      (write 'query:Known->X-scored)
	      (lambda (bucket*) (query:Known->X-scored (list subject) b2 objects bucket*)))
	     (else
	      (write 'known)
	      (lambda (bucket*) (query:Known->X-scored subjects b2 objects bucket*)))))
           (r
            (if q
                (if autogrow? (auto-grow q TOP_BUCKET_NUMBERS_AUTOGROW 100) (q TOP_BUCKET_NUMBERS))
                '())))
      (display "RETURNING")
      (set! r (cleanup r))
      (displayln "")
      (flush-output)
      r)))


(define (maybe-cdr x)
  (and x (cdr x)))

(define (handle-query1-request request)
  (define params (request-bindings request))
  (response/jsexpr
   (generate-query1-response (maybe-cdr (assoc 'subject params)) (maybe-cdr (assoc 'predicate params)) (maybe-cdr (assoc 'object params)) )))

(define (empty? x)
  (or (string=? "" x) (not x)))

(define (commasep->list x)
  (string-split x #rx","))

(define (entity-query-set x)
  (cond
   ((empty? x)
    #f)
   ((string-prefix? x "biolink:")
    (set->list
     (get-non-deprecated/mixin/abstract-ins-and-descendent-classes*-in-db
      (list x))))
   (else
    (set->list (curie-synonyms-and-descendents (commasep->list x))))))

(define (entity-query-unknown? x)
  (cond
   ((empty? x)
    #t)
   ((string-prefix? x "biolink:")
    #t)
   (else #f)))

(define (generate-query1-response subject predicate object)
  (displayln (format "Handling query1 expression ~a ~a ~a" subject predicate object))
  (flush-output)
  (let ((predicates
         (set->list
          (if (empty? predicate)
              all-predicates
              (get-non-deprecated-mixed-ins-and-descendent-predicates*-in-db
               (if (string=? "biolink:treats" predicate) '("biolink:treats" "biolink:treats_or_applied_or_studied_to_treat") (list predicate))))))
        (subjects (entity-query-set subject))
        (objects (entity-query-set object))
        (query-fun (cond
                    ((entity-query-unknown? subject) query:X->Known)
                    ((entity-query-unknown? object) query:Known->X)
                    (else
                     (displayln "Warning: no clear direction!")
                     query:X->Known))))
    ;; (displayln "Subjects:")
    ;; (write subjects)
    ;; (displayln "")
    ;; (displayln "Predicates:")
    ;; (write predicates)
    ;; (displayln "")
    ;; (displayln "Objects:")
    ;; (write objects)
    ;; (displayln "")
    (let ((r (query-fun subjects predicates objects)))
      (display "RETURNING")
      ;;(write r)
      (displayln "")
      (flush-output)
      r)))

(define (send-ready-signal)
  ;; Sends signal to `pm2` when the server is ready
  (system "kill -s SIGUSR2 $PM2_PID"))

(define (serve)
  (serve/servlet start
                 #:servlet-path ""
                 #:port port
                 #:servlet-regexp #rx""
                 #:max-waiting max-waiting
                 #:launch-browser? #false)
  (send-ready-signal))
(serve)
