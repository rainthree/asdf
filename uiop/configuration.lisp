;;;; ---------------------------------------------------------------------------
;;;; Generic support for configuration files

(uiop/package:define-package :uiop/configuration
  (:nicknames :asdf/configuration)
  (:recycle :uiop/configuration :asdf/configuration :asdf)
  (:use :uiop/common-lisp :uiop/utility
   :uiop/os :uiop/pathname :uiop/filesystem :uiop/stream :uiop/image :uiop/lisp-build)
  (:export
   #:user-configuration-directories #:system-configuration-directories ;; implemented in backward-driver
   #:in-first-directory #:in-user-configuration-directory #:in-system-configuration-directory ;; idem
   #:get-folder-path
   #:data-home-pathname #:config-home-pathname #:data-search-pathnames #:config-search-pathnames
   #:cache-home-pathname #:runtime-dir-pathname #:config-system-pathnames
   #:clean-search-pathnames #:data-pathnames #:config-pathnames
   #:find-preferred-file #:find-data-pathname #:find-config-pathname
   #:validate-configuration-form #:validate-configuration-file #:validate-configuration-directory
   #:configuration-inheritance-directive-p
   #:report-invalid-form #:invalid-configuration #:*ignored-configuration-form* #:*user-cache*
   #:*clear-configuration-hook* #:clear-configuration #:register-clear-configuration-hook
   #:resolve-location #:location-designator-p #:location-function-p #:*here-directory*
   #:resolve-relative-location #:resolve-absolute-location #:upgrade-configuration))
(in-package :uiop/configuration)

(with-upgradability ()
  (define-condition invalid-configuration ()
    ((form :reader condition-form :initarg :form)
     (location :reader condition-location :initarg :location)
     (format :reader condition-format :initarg :format)
     (arguments :reader condition-arguments :initarg :arguments :initform nil))
    (:report (lambda (c s)
               (format s (compatfmt "~@<~? (will be skipped)~@:>")
                       (condition-format c)
                       (list* (condition-form c) (condition-location c)
                              (condition-arguments c))))))

  (defun configuration-inheritance-directive-p (x)
    "Is X a configuration inheritance directive?"
    (let ((kw '(:inherit-configuration :ignore-inherited-configuration)))
      (or (member x kw)
          (and (length=n-p x 1) (member (car x) kw)))))

  (defun report-invalid-form (reporter &rest args)
    "Report an invalid form according to REPORTER and various ARGS"
    (etypecase reporter
      (null
       (apply 'error 'invalid-configuration args))
      (function
       (apply reporter args))
      ((or symbol string)
       (apply 'error reporter args))
      (cons
       (apply 'apply (append reporter args)))))

  (defvar *ignored-configuration-form* nil
    "Have configuration forms been ignored while parsing the configuration?")

  (defun validate-configuration-form (form tag directive-validator
                                            &key location invalid-form-reporter)
    "Validate a configuration FORM"
    (unless (and (consp form) (eq (car form) tag))
      (setf *ignored-configuration-form* t)
      (report-invalid-form invalid-form-reporter :form form :location location)
      (return-from validate-configuration-form nil))
    (loop :with inherit = 0 :with ignore-invalid-p = nil :with x = (list tag)
          :for directive :in (cdr form)
          :when (cond
                  ((configuration-inheritance-directive-p directive)
                   (incf inherit) t)
                  ((eq directive :ignore-invalid-entries)
                   (setf ignore-invalid-p t) t)
                  ((funcall directive-validator directive)
                   t)
                  (ignore-invalid-p
                   nil)
                  (t
                   (setf *ignored-configuration-form* t)
                   (report-invalid-form invalid-form-reporter :form directive :location location)
                   nil))
            :do (push directive x)
          :finally
             (unless (= inherit 1)
               (report-invalid-form invalid-form-reporter
                                    :form form :location location
                                    ;; we throw away the form and location arguments, hence the ~2*
                                    ;; this is necessary because of the report in INVALID-CONFIGURATION
                                    :format (compatfmt "~@<Invalid source registry ~S~@[ in ~S~]. ~
                                                        One and only one of ~S or ~S is required.~@:>")
                                    :arguments '(:inherit-configuration :ignore-inherited-configuration)))
             (return (nreverse x))))

  (defun validate-configuration-file (file validator &key description)
    "Validate a configuration file for conformance of its form with the validator function"
    (let ((forms (read-file-forms file)))
      (unless (length=n-p forms 1)
        (error (compatfmt "~@<One and only one form allowed for ~A. Got: ~3i~_~S~@:>~%")
               description forms))
      (funcall validator (car forms) :location file)))

  (defun validate-configuration-directory (directory tag validator &key invalid-form-reporter)
    "Map the VALIDATOR across the .conf files in DIRECTORY, the TAG will
be applied to the results to yield a configuration form.  Current
values of TAG include :source-registry and :output-translations."
    (let ((files (sort (ignore-errors ;; SORT w/o COPY-LIST is OK: DIRECTORY returns a fresh list
                        (remove-if
                         'hidden-pathname-p
                         (directory* (make-pathname :name *wild* :type "conf" :defaults directory))))
                       #'string< :key #'namestring)))
      `(,tag
        ,@(loop :for file :in files :append
                                    (loop :with ignore-invalid-p = nil
                                          :for form :in (read-file-forms file)
                                          :when (eq form :ignore-invalid-entries)
                                            :do (setf ignore-invalid-p t)
                                          :else
                                            :when (funcall validator form)
                                              :collect form
                                          :else
                                            :when ignore-invalid-p
                                              :do (setf *ignored-configuration-form* t)
                                          :else
                                            :do (report-invalid-form invalid-form-reporter :form form :location file)))
        :inherit-configuration)))

  (defun resolve-relative-location (x &key ensure-directory wilden)
    "Given a designator X for an relative location, resolve it to a pathname"
    (ensure-pathname
     (etypecase x
       (null nil)
       (pathname x)
       (string (parse-unix-namestring
                x :ensure-directory ensure-directory))
       (cons
        (if (null (cdr x))
            (resolve-relative-location
             (car x) :ensure-directory ensure-directory :wilden wilden)
            (let* ((car (resolve-relative-location
                         (car x) :ensure-directory t :wilden nil)))
              (merge-pathnames*
               (resolve-relative-location
                (cdr x) :ensure-directory ensure-directory :wilden wilden)
               car))))
       ((eql :*/) *wild-directory*)
       ((eql :**/) *wild-inferiors*)
       ((eql :*.*.*) *wild-file*)
       ((eql :implementation)
        (parse-unix-namestring
         (implementation-identifier) :ensure-directory t))
       ((eql :implementation-type)
        (parse-unix-namestring
         (string-downcase (implementation-type)) :ensure-directory t))
       ((eql :hostname)
        (parse-unix-namestring (hostname) :ensure-directory t)))
     :wilden (and wilden (not (pathnamep x)) (not (member x '(:*/ :**/ :*.*.*))))
     :want-relative t))

  (defvar *here-directory* nil
    "This special variable is bound to the currect directory during calls to
PROCESS-SOURCE-REGISTRY in order that we be able to interpret the :here
directive.")

  (defvar *user-cache* nil
    "A specification as per RESOLVE-LOCATION of where the user keeps his FASL cache")

  (defun resolve-absolute-location (x &key ensure-directory wilden)
    "Given a designator X for an absolute location, resolve it to a pathname"
    (ensure-pathname
     (etypecase x
       (null nil)
       (pathname x)
       (string
        (let ((p #-mcl (parse-namestring x)
                 #+mcl (probe-posix x)))
          #+mcl (unless p (error "POSIX pathname ~S does not exist" x))
          (if ensure-directory (ensure-directory-pathname p) p)))
       (cons
        (return-from resolve-absolute-location
          (if (null (cdr x))
              (resolve-absolute-location
               (car x) :ensure-directory ensure-directory :wilden wilden)
              (merge-pathnames*
               (resolve-relative-location
                (cdr x) :ensure-directory ensure-directory :wilden wilden)
               (resolve-absolute-location
                (car x) :ensure-directory t :wilden nil)))))
       ((eql :root)
        ;; special magic! we return a relative pathname,
        ;; but what it means to the output-translations is
        ;; "relative to the root of the source pathname's host and device".
        (return-from resolve-absolute-location
          (let ((p (make-pathname* :directory '(:relative))))
            (if wilden (wilden p) p))))
       ((eql :home) (user-homedir-pathname))
       ((eql :here) (resolve-absolute-location
                     (or *here-directory* (pathname-directory-pathname (load-pathname)))
                     :ensure-directory t :wilden nil))
       ((eql :user-cache) (resolve-absolute-location
                           *user-cache* :ensure-directory t :wilden nil)))
     :wilden (and wilden (not (pathnamep x)))
     :resolve-symlinks *resolve-symlinks*
     :want-absolute t))

  ;; Try to override declaration in previous versions of ASDF.
  (declaim (ftype (function (t &key (:directory boolean) (:wilden boolean)
                               (:ensure-directory boolean)) t) resolve-location))

  (defun* (resolve-location) (x &key ensure-directory wilden directory)
    "Resolve location designator X into a PATHNAME"
    ;; :directory backward compatibility, until 2014-01-16: accept directory as well as ensure-directory
    (loop* :with dirp = (or directory ensure-directory)
           :with (first . rest) = (if (atom x) (list x) x)
           :with path = (or (resolve-absolute-location
                             first :ensure-directory (and (or dirp rest) t)
                                   :wilden (and wilden (null rest)))
                            (return nil))
           :for (element . morep) :on rest
           :for dir = (and (or morep dirp) t)
           :for wild = (and wilden (not morep))
           :for sub = (merge-pathnames*
                       (resolve-relative-location
                        element :ensure-directory dir :wilden wild)
                       path)
           :do (setf path (if (absolute-pathname-p sub) (resolve-symlinks* sub) sub))
           :finally (return path)))

  (defun location-designator-p (x)
    "Is X a designator for a location?"
    (flet ((absolute-component-p (c)
             (typep c '(or string pathname
                        (member :root :home :here :user-cache))))
           (relative-component-p (c)
             (typep c '(or string pathname
                        (member :*/ :**/ :*.*.* :implementation :implementation-type)))))
      (or (typep x 'boolean)
          (absolute-component-p x)
          (and (consp x) (absolute-component-p (first x)) (every #'relative-component-p (rest x))))))

  (defun location-function-p (x)
    "Is X the specification of a location function?"
    (and
     (length=n-p x 2)
     (eq (car x) :function)))

  (defvar *clear-configuration-hook* '())

  (defun register-clear-configuration-hook (hook-function &optional call-now-p)
    "Register a function to be called when clearing configuration"
    (register-hook-function '*clear-configuration-hook* hook-function call-now-p))

  (defun clear-configuration ()
    "Call the functions in *CLEAR-CONFIGURATION-HOOK*"
    (call-functions *clear-configuration-hook*))

  (register-image-dump-hook 'clear-configuration)

  (defun upgrade-configuration ()
    "If a previous version of ASDF failed to read some configuration, try again now."
    (when *ignored-configuration-form*
      (clear-configuration)
      (setf *ignored-configuration-form* nil)))


  (defun get-folder-path (folder)
    "Semi-portable implementation of a subset of LispWorks' sys:get-folder-path,
this function tries to locate the Windows FOLDER for one of
:LOCAL-APPDATA, :APPDATA or :COMMON-APPDATA.
     Returns NIL when the folder is not defined (e.g., not on Windows)."
    (or #+(and lispworks mswindows) (sys:get-folder-path folder)
        ;; read-windows-registry HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders\AppData
        (ecase folder
          (:local-appdata (or (getenv-absolute-directory "LOCALAPPDATA")
                              (subpathname* (getenv-absolute-directory "APPDATA") "Local")))
          (:appdata (getenv-absolute-directory "APPDATA"))
          (:common-appdata (or (getenv-absolute-directory "ALLUSERSAPPDATA")
                               (subpathname* (getenv-absolute-directory "ALLUSERSPROFILE") "Application Data/"))))))

  ;; Support for the XDG Base Directory Specification
  (defun data-home-pathname (&optional app &rest more)
    "path for user specific data files"
    (resolve-location
     `(,(os-cond
         ((os-windows-p) (or (get-folder-path :local-appdata)
                             (subpathname* (get-folder-path :appdata) "Local/")))
         (t (or (getenv-absolute-directory "XDG_DATA_HOME")
                (subpathname (user-homedir-pathname) ".local/share/"))))
       ,app ,more)))

  (defun config-home-pathname (&optional app &rest more)
    "path for user specific configuration files"
    (os-cond
     ((os-windows-p) (apply 'data-home-path app "config/" more))
     (t (resolve-absolute-location
         `(,(or (getenv-absolute-directory "XDG_CONFIG_HOME")
                (subpathname (user-homedir-pathname) ".config/"))
           ,app ,more)))))

  (defun data-search-pathnames (&optional app &rest more)
    "the preference-ordered set of additional paths to search for data files"
    (mapcar #'(lambda (d) (resolve-location `(,d ,app ,more)))
            (os-cond
              ((os-windows-p) (mapcar 'get-folder-path '(:appdata :common-appdata)))
              (t (or (getenv-absolute-directories "XDG_DATA_DIRS")
                     (mapcar 'parse-unix-namestring '("/usr/local/share/" "/opt/local/share/" "/usr/share/")))))))

  (defun config-search-pathnames (&optional app &rest more)
    "the preference-ordered set of additional base paths to search for configuration files"
    (os-cond
     ((os-windows-p) (apply 'data-search-pathnames app "config/" more))
     (t (mapcar #'(lambda (d) (resolve-location `(,d ,app ,more)))
                (or (getenv-absolute-directories "XDG_CONFIG_DIRS")
                    (mapcar 'parse-unix-namestring
                            (list "/etc/xdg/"
                                  "/usr/local/etc/"
                                  "/opt/local/etc/")))))))

  (defun cache-home-pathname (&optional app &rest more)
    "the base directory relative to which user specific non-essential data files should be stored"
    (os-cond
     ((os-windows-p) (data-home-pathname app "cache" more))
     (t (resolve-location `(,(or (getenv-absolute-directory "XDG_CACHE_HOME")
                                 (subpathname* (user-homedir-pathname) ".cache/")) ,app ,more)))))

  (defun runtime-dir-pathname (&optional app &rest more)
    "pathname for user-specific non-essential runtime files and other file objects"
    ;; (such as sockets, named pipes, ...)
    ;; The XDG spec says that if not provided by the login system, the application should
    ;; issue a warning and provide a replacement. UIOP is not equipped to do that and returns NIL.
    (os-cond
     ((not (os-windows-p))
      (resolve-location `(,(getenv-absolute-directory "XDG_RUNTIME_DIR") ,app ,more)))))

  (defun config-system-pathnames (&optional app &rest more)
    "Determine system user configuration directories"
    (os-cond
     ((os-unix-p) (list (resolve-location `(,(parse-unix-namestring "/etc/") ,app ,more))))))

  (defun clean-search-pathnames (dirs)
    "Parse strings as unix namestrings and remove duplicates and non absolute-pathnames in a list"
    (remove-duplicates (remove-if-not #'absolute-pathname-p dirs) :from-end t :test 'equal))

  (defun data-pathnames (&optional app &rest more)
    "Return a list of absolute pathnames for application data directories.  With APP,
returns directory for data for that application, without APP, returns the set of directories
for storing all application configurations."
    (clean-search-pathnames
     `(,(data-home-pathname app more)
       ,@(data-search-pathnames app more))))

  (defun config-pathnames (&optional app &rest more)
    "Return a list of pathnames for application configuration. Without the APP argument,
returns pathnames for directories that contain all of the configuration information."
    (clean-search-pathnames
     `(,(config-home-pathname app more)
       ,@(config-search-pathnames app more))))

  (defun find-preferred-file (files &key (direction :input))
    "Find first file in the list of FILES that exists (for direction :input or :probe)
or just the first one (for direction :output or :io).
    Note that when we say \"file\" here, the files in question may be directories."
    (find-if (ecase direction ((:probe :input) 'probe-file*) ((:output :io) 'identity)) files))

  (defun find-data-pathname (&optional app more (direction :input))
    (find-preferred-file (data-pathnames app more) :direction direction))

  (defun find-config-pathname (&optional app more (direction :input))
    (find-preferred-file (config-pathnames app more) :direction direction))

  (defun compute-user-cache ()
    "Compute (and return) the location of the default user-cache for translate-output
objects. Side-effects for cached file location computation."
    (setf *user-cache* (cache-home-pathname "common-lisp" :implementation)))
  (register-image-restore-hook 'compute-user-cache))
