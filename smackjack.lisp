
;;;; smackjack.lisp

(in-package #:smackjack)

;;; "smackjack" goes here. Hacks and glory await!

(defclass ajax-function ()
  ((name :reader name
         :initarg :name
         :type symbol
         :documentation "symbol name of the lisp ajax function")
   (remote-name
    :accessor remote-name
    :initarg :remote-name
    :initform nil
    :type symbol
    :documentation "remote name of the lisp ajax function")
   (method
    :accessor http-method
    :initarg :method
    :initform :get
    :type '(member :post :get)
    :documentation "http method of the lisp ajax function")
   (json-p
    :accessor json-p
    :initarg :json-p
    :initform nil
    :type boolean
    :documentation "the response is a json object evaluated in the client before callback")
   (content-type
    :initarg :content-type :type string
    :accessor content-type
    :initform "text/xml; charset=\"utf-8\""
    :documentation "The http content type that is sent with each response, ignored if json is true")))

(defclass ajax-processor ()
  ((ajax-functions 
    :accessor ajax-functions :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Maps the symbol names of the remoted functions to
                    their ajax-function object")
   (ajax-namespace
    :initarg :ajax-function-prefix :initform 'smackjack
    :accessor ajax-namespace
    :type symbol
    :documentation "Create a namespace object for generated javascript code")
   (ajax-functions-namespace-p
    :initarg :ajax-functions-namespace-p :initform t
    :accessor ajax-functions-namespace-p
    :type boolean
    :documentation "Place javascript functions corresponding
                    to lisp functions in the ajax-namespace")   
   (ajax-function-prefix
    :initarg :ajax-function-prefix :initform nil
    :accessor ajax-function-prefix
    :type symbol
    :documentation "Prefix for javascript functions corresponding
                    to lisp functions")
   
   (ht-simple-ajax-symbols-p  ;; should be removed in the future.
    :initarg :ht-simple-ajax-symbols-p
    :accessor ht-simple-ajax-symbols-p
    :initform nil
    :type boolean
    :documentation "use ht-simple-ajax symbol processor to generate
                    compatible ht-simple-ajax compatible code")
   (server-uri 
    :initarg :server-uri :initform "/ajax" :accessor server-uri
    :type string
    :documentation "The uri which is used to handle ajax request")
   (default-content-type
    :initarg :default-content-type :type string
    :accessor default-content-type
    :initform "text/xml; charset=\"utf-8\""
    :documentation "The http content type that is sent with each response")
   (reply-external-format 
    :initarg :reply-external-format :type flexi-streams::external-format
    :accessor reply-external-format :initform hunchentoot::+utf-8+
    :documentation "The format for the character output stream")))

(defclass ht-simple-ajax-processor (ajax-processor)
  ((ajax-namespace :initform nil)
   (ajax-functions-namespace-p :initform nil)
   (ajax-function-prefix :initform 'ajax)
   (ht-simple-ajax-symbols-p :initform t)))

(defgeneric create-ajax-dispatcher (processor))
(defmethod create-ajax-dispatcher ((processor ajax-processor))
  "Creates a hunchentoot dispatcher for an ajax processor"
  (create-prefix-dispatcher (server-uri processor)
                            #'(lambda () (call-lisp-function processor))))


(defun make-js-symbol (symbol)
  "helper function for making 'foo_bar_' out of 'foo-bar?' "
  (loop with string = (string-downcase symbol)
     for c across "?-<>"
     do (setf string (substitute #\_ c string))
     finally (return string)))

(defun make-ps-symbol (symbol)
  (symbolicate (string-upcase (make-js-symbol symbol))))



(defgeneric remotify-function (processor function-name
                               &key method remote-name content-type json-p))
(defmethod  remotify-function ((processor ajax-processor) function-name
                               &key (method :get) remote-name content-type json-p)
  (setf (gethash (symbol-name function-name) (ajax-functions processor))
        (make-instance 'ajax-function
                       :name function-name
                       :method method
                       :remote-name remote-name
                       :content-type content-type
                       :json-p json-p)))

(defgeneric un-remotify-function (processor function-name))

(defmethod un-remotify-function ((processor ajax-processor) symbol-or-name)
  (let ((func-name (if (symbolp symbol-or-name)
                       (symbol-name symbol-or-name)
                       symbol-or-name)))
    (unless (and func-name (stringp func-name))
      (error "Invalid name ~S in UNEXPORT-FUNC" symbol-or-name))
    (remhash (string-upcase func-name) (ajax-functions processor))))


(defmacro defun-ajax (name lambda-list (processor &rest remote-keys) &body body)
  "Declares a defun that can be called from a client page.
Example: (defun-ajax func1 (arg1 arg2) (*ajax-processor*)
   (do-stuff))"
  `(progn
     (defun ,name ,lambda-list ,@body)
     (remotify-function ,processor ',name ,@remote-keys)))

(defgeneric ajax-function-name (processor ajax-fn))
(defmethod ajax-function-name ((processor ajax-processor)
                               (ajax-fn ajax-function))
  (let ((compat (ht-simple-ajax-symbols-p processor))
        (prefix (ajax-function-prefix processor))
        (name   (or (remote-name ajax-fn)
                    (name ajax-fn))))
    (funcall (if compat #'make-ps-symbol #'identity)
             (if prefix
                 (symbolicate prefix '- name)
                 name))))

(defgeneric ajax-ps-function (processor ajax-fn))
(defmethod ajax-ps-function ((processor ajax-processor) (ajax-fn ajax-function))
  (let* ((namespace (ajax-namespace processor))
         (ajax-fns-in-ns (and namespace (ajax-functions-namespace-p processor)))
         (ajax-name (ajax-function-name processor ajax-fn))
         (lisp-name (name ajax-fn))
         (ajax-params  (mapcar (if (ht-simple-ajax-symbols-p processor)
                                   #'make-ps-symbol
                                   #'identity)
                               (arglist lisp-name)))
         (ajax-call (if (and namespace (not ajax-fns-in-ns))
                        `(@ ,namespace ajax-call)
                        'ajax-call)))
    `(defun ,ajax-name ,(append ajax-params '(callback error-handler))
       (,ajax-call ,(string lisp-name)
                   (array ,@ajax-params)
                   ,(string (http-method ajax-fn))
                   callback
                   error-handler))))

(defun ps-http-request ()
  '(progn
    (defvar http-factory nil)
    (defvar http-factories
      (array
       (lambda () (return (new (*x-m-l-http-request))))
       (lambda () (return (new (*active-x-object "Msxml2.XMLHTTP"))))
       (lambda () (return (new (*active-x-object "Microsoft.XMLHTTP"))))))
    (defun http-new-request ()
      (unless (= http-factory nil)
        (return (http-factory)))
      (let ((request nil))
        (do* ((i 0 (1+ i))
              (l (length http-factories))
              (factory (aref http-factories i) (aref http-factories i)))
             ((or (!= request null) (>= i l)))
          (try
           (setf request (factory))
           (unless (= request null)
             (setf http-factory factory))
           (:catch (e) )))
        (if (= request null)
            (progn
              (setf http-factory
                    (lambda ()
                      (throw (new (*error "XMLHttpRequest not supported")))))
              (http-factory))
            request)))))

(defgeneric ps-fetch-uri (processor))
(defmethod ps-fetch-uri ((processor ajax-processor))
  (declare (ignore processor))
  '(defun fetch-uri (uri callback &optional (method "GET") (body nil) error-handler )
    (let ((request (http-new-request)))
      (unless request
        (alert "Browser couldn't make a request object."))
      (with-slots (open ready-state status status-text response-x-m-l
                   onreadystatechange send set-request-header) request 
        (funcall open method uri t)
        (setf onreadystatechange
              (lambda ()
                (when (/= 4 ready-state)
                  (return))
                (if (or (and (>= status 200) (< status 300))
                        (== status 304))
                    (unless (== callback nil)
                      (callback response-x-m-l))
                    (if (== error-handler nil)
                        (alert (+ "Error while fetching URI " uri " " status " " status-text))
                        (error-handler request)))
                (return)))
        (when (equal method "POST")
          (funcall set-request-header
                   "Content-Type"
                   "application/x-www-form-urlencoded"))
        (funcall send body))
      (return))))


(defun  ps-encode-args ()
  '(defun ajax-encode-args (args)
     (let ((s ""))
       (dotimes (i (length args) s)
         (when (> i 0)
           (incf s "&"))
         (incf s (+ "arg" i "=" (encode-u-r-i-component (aref args i))))))))

(defgeneric ps-ajax-call (processor))
(defmethod ps-ajax-call ((processor ajax-processor))  
  `(defun ajax-call (func args &optional (method "GET") callback error-handler)
     (let ((uri (+ ,(server-uri processor) "/"
                   (encode-u-r-i-component func) "/"))
           (ajax-args (ajax-encode-args args))
           (body nil))
       (when (and (equal method "GET")
                  (> (length args) 0))
         (incf uri (+ "?" ajax-args)))
       (when (equal method "POST")
         (setf body ajax-args))
       (fetch-uri uri callback method body error-handler))))

(defgeneric ps-ajax-post (processor))
(defmethod ps-ajax-post ((processor ajax-processor))  
  `(defun ajax-post (func callback args)
     (let ((uri (+ ,(server-uri processor) "/"
                   (encode-u-r-i-component func) "/")))
       (fetch-uri uri callback "POST" (ajax-encode-args args)))))


(defgeneric generate-prologue-javascript (processor))
(defmethod generate-prologue-javascript ((processor ajax-processor))
  (let* ((namespace (ajax-namespace processor))
         (ajax-fns-in-ns (and namespace (ajax-functions-namespace-p processor)))
         (ajax-fns nil)
         (ajax-globals nil))
    (maphash-values (lambda (fn)
                      (push (ajax-ps-function processor fn) ajax-fns)
                      (when ajax-fns-in-ns
                        (let ((ajax-name (ajax-function-name processor fn)))
                          (push `(setf (@ ,namespace ,ajax-name) ,ajax-name)
                                ajax-globals))))
                    (ajax-functions processor))
    (ps*
     (if namespace
         `(progn
            (var ,namespace (create))
            (funcall
             (lambda ()
               ,(ps-http-request)
               ,(ps-fetch-uri processor)
               ,(ps-encode-args)
               ,(ps-ajax-call processor)
               ,(if ajax-fns-in-ns
                    `(progn ,@ajax-fns ,@ajax-globals)
                    `(progn
                       (setf (@ ,namespace ajax-call) ajax-call)))
               (return)))
            ,(unless ajax-fns-in-ns
               `(progn ,@ajax-fns)))
         (list* 'progn
                (ps-http-request)
                (ps-fetch-uri processor)
                (ps-encode-args)
                (ps-ajax-call processor)
                ajax-fns)))))



;; in the future possibly generate with a html generator.
;; right now exists to hide ugly html.
(defun html-script-cdata (js &key (newlines t))
  "html script/cdata wrapper for javascript
   wraps javascript in a <script> ... </script> html element"
  (let ((newline (if newlines (string #\newline) "")))
    (concatenate 'string
                 "<script type='text/javascript'>" newline
                 "//<![CDATA[ " newline
                 js newline
                 "//]]>" newline
                 "</script>")))
  
    


(defgeneric generate-prologue (processor))
(defmethod generate-prologue ((processor ajax-processor))
  "Creates a <script> ... </script> html element that contains all the
   client-side javascript code for the ajax communication. Include this 
   script in the <head> </head> of each html page"
  (html-script-cdata (generate-prologue-javascript processor)))



(defun call-lisp-function (processor)
  "This is called from hunchentoot on each ajax request. It parses the 
   parameters from the http request, calls the lisp function and returns
   the response."
  (let* ((fn-name (string-trim "/" (subseq (script-name* *request*)
                                           (length (server-uri processor)))))
         (fn  (gethash fn-name (ajax-functions processor)))
         (args (mapcar #'cdr (funcall (if (eq :post (http-method fn))
                                          #'post-parameters*
                                          #'get-parameters*)
                                      *request*))))
    (unless fn
      (error "Error in call-lisp-function: no such function: ~A" fn-name))
    (unless (= (length (arglist (name fn))) (length args))
      (error "Error in call-lisp-function: wrong number args: ~A ~A" fn-name args))
    (setf (reply-external-format*) (reply-external-format processor))
    (setf (content-type*) (or (content-type fn)
                              (default-content-type processor)))
    (no-cache)
    (concatenate 'string
                 "<?xml version=\"1.0\"?>"
                 (string #\newline)
                 "<response xmlns='http://www.w3.org/1999/xhtml'>"
                 (apply (name fn) args)
                 "</response>")))