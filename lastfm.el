;; -*- lexical-binding: t -*-

(require 'request)
(require 'cl-lib)
(require 'elquery)
(require 's)

;;;; Configuration and setup
(defconst lastfm--url "http://ws.audioscrobbler.com/2.0/"
  "The URL for the last.fm API version 2 used to make all the
  method calls.")

(defconst lastfm--config-file
  (let ((f (concat (xdg-config-home) "/.lastfmrc")))
    (or (file-exists-p f)
        (with-temp-file f
          (insert "(CONFIG
  :API-KEY \"\"
  :SHARED-SECRET \"\"
  :USERNAME \"\")")))
    f)
  "User config file holding the last.fm api-key, shared-secret,
username and the session key. If the file does not exist when the
package is loaded, build it with empty values.")

;; The values of these configs are taken from the user config file.
(defvar lastfm--api-key)
(defvar lastfm--shared-secret)
(defvar lastfm--username)
(defvar lastfm--sk)

(defun lastfm--read-config-file ()
  "Return the config file contents as a Lisp object"
  (with-temp-buffer
    (insert-file-contents lastfm--config-file)
    (read (buffer-string))))

(defun lastfm--set-config-parameters ()
  "Read the config file and set the config parameters used
throught the package."
  (let ((config (cl-rest (lastfm--read-config-file))))
    (cl-mapcar (lambda (key value)
                 (setf (pcase key
                         (:API-KEY       lastfm--api-key)
                         (:SHARED-SECRET lastfm--shared-secret)
                         (:USERNAME      lastfm--username)
                         (:SK            lastfm--sk))
                       value))
               (cl-remove-if #'stringp config)
               (cl-remove-if #'symbolp config))))

(lastfm--set-config-parameters)         ;set params on start-up.

(defun lastfm-generate-session-key ()
  "Get an authorization token from last.fm and then ask the user
to grant persmission to his last.fm account. If granted, then ask
for the session key (sk) and append the sk value to the config's
file list of values."
  (let ((token (cl-first (lastfm-auth-gettoken))))
    ;; Ask the user to allow access.
    (browse-url (concat "http://www.last.fm/api/auth/?api_key="
                        lastfm--api-key
                        "&token=" token))
    (when (yes-or-no-p "Did you grant the application persmission 
to access your Last.fm account? ")
      ;; If permission granted, get the sk and update the config file.
      (let* ((sk (cl-first (lastfm-auth-getsession token)))
             (config (lastfm--read-config-file))
             (config-with-sk (append config (list :SK sk))))
        (with-temp-file lastfm--config-file
          (insert (prin1-to-string config-with-sk))))
      (lastfm--set-config-parameters)   ;set params on config file update.
      )))


;;;; Methods list, and functions for it's manipulation
(defconst lastfm--methods-pretty
  '((album
     (addtags    :yes (artist album tags) ()           "lfm")
     (getinfo    :no  (artist album)      ()           "track > name")
     (gettags    :yes (artist album)      ()           "tag name")
     (gettoptags :no  (artist album)      ()           "tag name")
     (removetag  :yes (artist album tag)  ()           "lfm")
     (search     :no  (album)             ((limit 10)) "album artist"))
    
    (artist
     (addtags       :yes (artist tags) () "lfm")
     (getcorrection :no  (artist) ()       "artist name")
     (getinfo       :no  (artist) ()       "bio summary")
     (getsimilar    :no  (artist) ((limit lastfm--similar-limit)
                                   (user lastfm--username))
                    "artist name")
     (gettags       :yes (artist)     ()                    "tag name")
     (gettopalbums  :no  (artist)     ((limit 50))          "album > name")
     (gettoptags    :no  (artist)     ()                    "tag name")
     (gettoptracks  :no  (artist)     ((limit 50) (page 1)) "track > name")
     (removetag     :yes (artist tag) ()                    "lfm")
     (search        :no  (artist)     ((limit 30))          "artist name"))
    
    (auth
     (gettoken   :sk ()      () "token")
     (getsession :sk (token) () "session key"))

    (chart
     (gettopartists :no () ((limit 50)) "name")
     (gettoptags    :no () ((limit 50)) "name")
     (gettoptracks  :no () ((limit 50)) "artist > name, track > name"))

    (geo
     (gettopartists :no (country) ((limit 50) (page 1)) "artist name")
     (gettoptracks  :no (country) ((limit 50) (page 1)) "track > name, artist > name"))

    (library
     (getartists :no () ((user lastfm--username) (limit 50) (page 1)) "artist name"))

    (tag
     (getinfo       :no (tag) ()                    "summary")
     (getsimilar    :no (tag) ()                    "tag name") ;Doesn't return anything
     (gettopalbums  :no (tag) ((limit 50) (page 1)) "album > name, artist > name")
     (gettopartists :no (tag) ((limit 50) (page 1)) "artist name")
     (gettoptags    :no () ()                       "name")
     (gettoptracks  :no (tag) ((limit 50) (page 1)) "track > name, artist > name"))
    
    (track
     (addtags          :yes (artist track tags) () "lfm")
     (getcorrection    :no (artist track) () "track > name, artist > name")
     (getinfo          :no (artist track) ()                          "album title")
     (getsimilar       :no (artist track) ((limit 10))
                       "track > name, artist > name")
     ;; Method doesn't return anything from lastfm
     (gettags          :yes (artist track) ()                         "name") 
     (gettoptags       :no (artist track) ()                          "name")
     (love             :yes (artist track) ()                         "lfm")
     (removetag        :yes (artist track tag) ()                     "lfm")
     (scrobble         :yes (artist track timestamp) ()               "lfm")
     (search           :no (track) ((artist nil) (limit 30) (page 1)) "name, artist")
     (unlove           :yes (artist track) ()                         "lfm")
     (updatenowplaying :yes (artist track)
                       ((album nil) (tracknumber nil) (context nil) (duration nil)
                        (albumartist nil)) "lfm"))
    
    (user
     (getfriends :no (user) ((recenttracks nil) (limit 50) (page 1)) "name")
     (getinfo :no () ((user lastfm--username)) "playcount, country")
     (getlovedtracks :no  () ((user lastfm--username) (limit 50) (page 1))
                     "artist > name, track > name" )
     (getpersonaltags :no (tag taggingtype)
                      ((user lastfm--username) (limit 50) (page 1)) "name")
     (getrecenttracks :no () ((user lastfm--username) (limit nil) (page nil)
                              (from nil) (to nil) (extended 0))
                      "artist, track > name")
     (gettopalbums :no () ((user lastfm--username) (period nil)
                           (limit nil) (page nil))
                   "artist > name, album > name")
     (gettopartists :no () ((user lastfm--username) (period nil)
                            (limit nil) (page nil))
                    "artist name")
     (gettoptags :no () ((user lastfm--username) (limit nil)) "tag name")
     (gettoptracks :no () ((user lastfm--username) (period nil)
                            (limit nil) (page nil))
                   "artist > name, track > name")
     (getweeklyalbumchart :no () ((user lastfm--username) (from nil) (to nil))
                          "album > artist, album > name")
     (getweeklyartistchart :no () ((user lastfm--username) (from nil) (to nil))
                           "album > name, artist > playcount")
     (getweeklytrackchart :no () ((user lastfm--username) (from nil) (to nil))
                          "track > artist, track > name")))
  "List of all the supported lastfm methods. A one liner
like (artist-getinfo ...) or (track-love ...) is more easier to
parse, but this is easier for the eyes. The latter, the
one-liner, is generated from this list and is the one actually
used for all the processing and generation of the user API. ")

(defconst lastfm--methods
  (let ((res nil))
    (mapcar
     (lambda (group)
       (mapcar
        (lambda (method)
          (push (cons (make-symbol
                       (concat (symbol-name (cl-first group)) "-"
                               (symbol-name (cl-first method))))
                      (cl-rest method))
                res))
        (cl-rest group)))
     lastfm--methods-pretty)
    (reverse res))
  "Generated list of one-liner lastfm methods from the pretty
list of methods. Each entry in this list is a complete lastm
method specification. It is used to generate the API for this
library.")

(defun lastfm--method-name (method)
  (cl-first method))

(defun lastfm--method-str (method)
  "The method name, as a string that can be used in a lastfm
request."
  (s-replace "-" "." (symbol-name (lastfm--method-name method))))

(defun lastfm--auth-p (method)
  "Does this method require authentication?"
  (eql (cl-second method) :yes))

(defun lastfm--sk-p (method)
  "Is this a method used for requesting the session key?"
  (eql (cl-second method) :sk))

(defun lastfm--method-params (method)
  "Minimum required parameters for succesfully calling this method."
  (cl-third method))

(defun lastfm--method-keyword-params (method)
  (cl-fourth method))

(defun lastfm--all-method-params (method)
  "A list of all the method parameters, required plus keyword."
  (append (lastfm--method-params method)
          (mapcar #'car (lastfm--method-keyword-params method))))

(defun lastfm--query-str (method)
  "XML query string for extracting the relevant data from the
lastfm response."
  (cl-fifth method))

(defun lastfm--multi-query-p (method)
  "Does the method require extracting multiple elements from the
  same response?"
  (s-contains-p "," (lastfm--query-str method)))

(defun lastfm--group-params-for-signing (params)
  "The signing procedure for authentication needs all the
parameters and values lumped together in one big string without
equal or ampersand symbols between them."
  (let ((res ""))
    (mapcar (lambda (s)
              (setf res (concat res (car s) (cdr s))))
            params)
    (concat res lastfm--shared-secret)))

(defun lastfm--build-params (method values)
  "Build the parameter/value list to be used by request :params."
  (let ((result
         `(;; The api key and method is needed for all calls.
           ("api_key" . ,lastfm--api-key)
           ("method" . ,(lastfm--method-str method))
           ;; Pair the user supplied values with the method parameters.  If no
           ;; value supplied for a given param, do not include it in the request.
           ,@(cl-remove-if #'null
              (cl-mapcar (lambda (param value)
                           (when value
                             (cons (symbol-name param) value)))
                         (lastfm--all-method-params method)
                         values)))))
    ;; Session Key(SK) parameter is needed for all auth services, but not for
    ;; the services used to obtain the SK.
    (when (lastfm--auth-p method)
      (push `("sk" . ,lastfm--sk) result))
    ;; If signing is needed, it should be added as the last parameter.
    (when (or (lastfm--auth-p method)
              (lastfm--sk-p method))
      ;; Params need to be in alphabetical order before signing.
      (setq result (cl-sort result #'string-lessp
                            :key #'cl-first))
      (add-to-list 'result
                   `("api_sig" . ,(md5 (lastfm--group-params-for-signing result)))
                   t))
    result))

(cl-defun lastfm--request (method &rest values)
  (let ((resp ""))
    (request lastfm--url
             :params   (lastfm--build-params method values)
             :parser   'buffer-string
             :type     "POST"
             :sync     t
             :complete (cl-function
                        (lambda (&key data &allow-other-keys)
                          (setq resp data))))
    resp))

(defun lastfm--parse-response (response method)
  "Extract the relevant information from the response, according
to the query string defined in the method."
  (let* ((resp-obj (elquery-read-string response))
         ;; Only one error expected, if any.
         (error-str (elquery-text
                     (cl-first (elquery-$ "error" resp-obj)))))
    (if error-str
        (error error-str)
      (let ((result
             (mapcar #'elquery-text
                     (elquery-$ (lastfm--query-str method)
                                resp-obj))))
        ;; In a request like artist-gettoptracks, the name of the artists will
        ;; fill the first half of the response list, while the song names the
        ;; remaining half. Split the response in half and group the artist with
        ;; the song name.
        (when (lastfm--multi-query-p method)
          (let ((nentries (/ (length result) 2)))
            (setq result
                  (-zip (-take nentries result)
                        (-drop nentries result)))))
        ;; elquery returns the last matched tag as the first element in the
        ;; response list. For toptracks, toptags, etc, this would be backwards.
        (reverse result)))))

(defun lastfm--build-function (method)
  (let* ((name-str (symbol-name (lastfm--method-name method)))
         (fn-name (intern (concat "lastfm-" name-str)))
         (params (lastfm--method-params method))
         (key-params (lastfm--method-keyword-params method)))
    `(cl-defun ,fn-name ,(if key-params
                             `(,@params &key ,@key-params)
                           `,@params)
       (lastfm--parse-response
        (lastfm--request ',method
                         ,@(if key-params
                               `(,@params ,@(mapcar #'car key-params))
                             `,params))
        ',method))))

(defmacro lastfm--build-api ()
  `(progn
     ,@(mapcar (lambda (method)
                 (lastfm--build-function method))
               lastfm--methods)))

(lastfm--build-api)

(provide 'lastfm)
