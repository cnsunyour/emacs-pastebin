;;; neopastebin.el --- pastebin.com interface to emacs -*- lexical-binding: t; -*-

;;; Copyright (C) 2013 by Daniel Hilst <danielhilst at gmail.com>

;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2, or (at your option)
;;; any later version.

;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.

;;; You should have received a copy of the GNU General Public License
;;; along with this program; see the file COPYING.  If not, write to the
;;; Free Software Foundation, Inc.,   51 Franklin Street, Fifth Floor,
;;; Boston, MA  02110-1301  USA

;;; Besides being a new interface, some parts were borrowed from old
;;; interface so I think is fair put the names here.
;;; Copyright (C) 2008 by Nic Ferrier <nic@ferrier.me.uk>
;;; Copyright (C) 2010 by Ivan Korotkov <twee@tweedle-dee.org>
;;; Copyright (C) 2012 by Filonenko Michael <filonenko.mikhail@gmail.com>

;;;
;;; Commentary:
;;;

;;;
;;; USAGE:
;;;
;;;     LOGIN
;;;     ~~~~~
;;;
;;; Puts this on your .emacs file
;;;
;;;   (pastebin-create-login :username "YOURUSER"
;;;                          :dev-key "YOURDEVKEY"
;;;                          :password-auth-source '(:host "pastebin.com" :user "YOURUSER"))
;;;
;;; with a matching entry on your ~/.authinfo.gpg:
;;;
;;;   machine pastebin.com login YOURUSER password YOURPASSWORD
;;;
;;; Login will only occur when you try to paste something or list your
;;; pastes, and the password is looked up through `auth-source' only
;;; when needed - it does not stay in memory between logins.
;;;
;;;
;;; -*- SECURITY REMINDER -*-
;;;
;;; Prefer `:password-auth-source' or `:password-function' over the legacy
;;; `:password' string: with the legacy form the password stays in memory
;;; until the first successful login clears it. The cached `usr-key' is a
;;; bearer token - run M-x pastebin-logout to discard it. Do not save
;;; `pastebin--default-user' with `desktop-save', and keep `url-http-debug'
;;; turned off: it logs request data, credentials included.
;;;
;;; Since pastebin uses https instead of http, your credentials are secure
;;; during transmission on network.
;;;
;;;
;;;     LISTING
;;;     ~~~~~~~
;;;
;;; M-x pastebin-list-buffer-refresh -> Fetch and list pastes on "list buffer"
;;;
;;; After logged you can list your pastes with command `pastebin-list-buffer-refresh'.
;;;
;;; Here is a list of keybinds from list buffer
;;;
;;; RET -> fetch paste and switch to it
;;; r ->   refresh list and list buffer
;;; d ->   delete paste
;;; t ->   order by title
;;; D ->   order by date
;;; f ->   order by format
;;; k ->   order by key
;;; p ->   order by private
;;;
;;;
;;;     PASTE BUFFERS
;;;     ~~~~~~~~~~~~~
;;;
;;; RET on a paste opens its content in "*paste: TITLE*". Known pastebin
;;; languages are highlighted through their major mode; for formats
;;; pastebin does not know, the paste title's file extension is matched
;;; against `auto-mode-alist' - an uploaded "init.fish" opens in
;;; fish-mode when that mode is installed. To highlight by hand just
;;; paste M-x <language>-mode: the pastebin minor mode survives the
;;; switch.
;;;
;;;
;;;     CREATING NEW PASTE
;;;     ~~~~~~~~~~~~~~~~~~
;;;
;;; M-x pastebin-new -> will create a new paste from current buffer
;;; M-x pastebin-new-from-selection -> from the region
;;; M-x pastebin-new-guest -> anonymous paste, no login needed
;;;
;;; The name of the paste is given from current buffer name
;;; The format from buffers major mode
;;; The expiration date is asked on every paste, RET keeps it forever
;;; No prefix makes the paste public, C-u makes it unlisted and
;;; C-u C-u makes it private. Guest pastes support public and
;;; unlisted only: no prefix is public, any prefix is unlisted
;;;

;;;
;;; Naming convention:
;;;
;;; pastebin-- prefix for internal stuff
;;; pastebin- prefix for user interface and customs
;;;
;;;
;;; DEPENDENCIES:
;;;
;;; eieio.el
;;; wid-edit
;;;

;;;
;;; Codes:
;;;
(require 'auth-source)
(require 'cl-lib)
(require 'eieio)
(require 'subr-x)
(require 'url)
(require 'wid-edit)

(defgroup pastebin nil
  "Pastebin -- pastebin.com client"
  :tag "Pastebin"
  :group 'tools)

;; Error symbols: both carry (USER-VISIBLE-MESSAGE RESPONSE-BODY), the
;; body is the full decoded response for callers to classify
(define-error 'pastebin-http-error "Pastebin HTTP error")
(define-error 'pastebin-api-error "Pastebin API error")

;; Customs

(defcustom pastebin-default-paste-list-limit 100
  "The number of pastes to retrieve by default"
  :type 'number
  :group 'pastebin)

(defcustom pastebin-post-request-login-url "https://pastebin.com/api/api_login.php"
  "Login url"
  :type 'string
  :group 'pastebin)

(defcustom pastebin-post-request-paste-url "https://pastebin.com/api/api_post.php"
  "Paste url"
  :type 'string
  :group 'pastebin)

(defcustom pastebin-post-request-raw-url "https://pastebin.com/api/api_raw.php"
  "Raw paste output url, serves `api_option=show_paste'"
  :type 'string
  :group 'pastebin)

;; Global variables

(defvar pastebin--mode-map nil
  "The pastebin keymap.")
(unless pastebin--mode-map
  (setq pastebin--mode-map (make-sparse-keymap))
  ;; C-x p is the project.el prefix since Emacs 27, use C-c C-u instead
  (define-key pastebin--mode-map (kbd "C-c C-u") 'pastebin-show-url))

(define-minor-mode pastebin-mode
  "Pastebin buffer mode, used to upload pastes automatically with S-C-x C-s"
  :lighter " pastebin"
  :group 'pastebin
  :keymap pastebin--mode-map)
;; survive major mode switches: pasting M-x <language>-mode in a paste
;; buffer keeps the pastebin keymap and lighter
(put 'pastebin-mode 'permanent-local t)

(defvar pastebin--type-assoc
  '((actionscript-mode . "actionscript")
    (ada-mode . "ada")
    (asm-mode . "asm")
    (sh-mode . "bash")
    (autoconf-mode . "bash")
    (bibtex-mode . "bibtex")
    (cmake-mode . "cmake")
    (c-mode . "c")
    (c++-mode . "cpp")
    (cobol-mode . "cobol")
    (conf-colon-mode . "properties")
    (conf-javaprop-mode . "properties")
    (conf-mode . "ini")
    (conf-space-mode . "properties")
    (conf-unix-mode . "ini")
    (conf-windows-mode . "ini")
    (cperl-mode . "perl")
    (csharp-mode . "csharp")
    (css-mode . "css")
    (delphi-mode . "delphi")
    (diff-mode . "diff")
    (ebuild-mode . "bash")
    (eiffel-mode . "eiffel")
    (emacs-lisp-mode . "lisp")
    (erlang-mode . "erlang")
    (erlang-shell-mode . "erlang")
    (espresso-mode . "javascript")
    (fortran-mode . "fortran")
    (glsl-mode . "glsl")
    (gnuplot-mode . "gnuplot")
    (graphviz-dot-mode . "dot")
    (haskell-mode . "haskell")
    (html-mode . "html4strict")
    (idl-mode . "idl")
    (inferior-haskell-mode . "haskell")
    (inferior-octave-mode . "octave")
    (inferior-python-mode . "python")
    (inferior-ruby-mode . "ruby")
    (java-mode . "java")
    (js2-mode . "javascript")
    (jython-mode . "python")
    (latex-mode . "latex")
    (lisp-mode . "lisp")
    (lisp-interaction-mode . "lisp")
    (lua-mode . "lua")
    (makefile-mode . "make")
    (makefile-automake-mode . "make")
    (makefile-gmake-mode . "make")
    (makefile-makepp-mode . "make")
    (makefile-bsdmake-mode . "make")
    (makefile-imake-mode . "make")
    (matlab-mode . "matlab")
    (nxml-mode . "xml")
    (oberon-mode . "oberon2")
    (objc-mode . "objc")
    (ocaml-mode . "ocaml")
    (octave-mode . "matlab")
    (pascal-mode . "pascal")
    (perl-mode . "perl")
    (php-mode . "php")
    (plsql-mode . "plsql")
    (po-mode . "gettext")
    (prolog-mode . "prolog")
    (python-2-mode . "python")
    (python-3-mode . "python")
    (python-basic-mode . "python")
    (python-mode . "python")
    (ruby-mode . "ruby")
    (scheme-mode . "lisp")
    (shell-mode . "bash")
    (smalltalk-mode . "smalltalk")
    (sql-mode . "sql")
    (tcl-mode . "tcl")
    (visual-basic-mode . "vb")
    (xml-mode . "xml")
    (yaml-mode . "properties")
    (text-mode . "text"))
  "Alist composed of major-mode names and corresponding pastebin highlight formats.")

(defvar pastebin--format-mode-alist
  '((ada . ada-mode)
    (asm . asm-mode)
    (actionscript . actionscript-mode)
    (bash . sh-mode)
    (bibtex . bibtex-mode)
    (c . c-mode)
    (cmake . cmake-mode)
    (cobol . cobol-mode)
    (cpp . c++-mode)
    (csharp . csharp-mode)
    (css . css-mode)
    (delphi . delphi-mode)
    (diff . diff-mode)
    (dot . graphviz-dot-mode)
    (eiffel . eiffel-mode)
    (erlang . erlang-mode)
    (fortran . fortran-mode)
    (gettext . po-mode)
    (glsl . glsl-mode)
    (gnuplot . gnuplot-mode)
    (haskell . haskell-mode)
    (html4strict . html-mode)
    (idl . idl-mode)
    (ini . conf-mode)
    (java . java-mode)
    (javascript . js-mode)
    (latex . latex-mode)
    (lisp . lisp-mode)
    (lua . lua-mode)
    (make . makefile-mode)
    (matlab . matlab-mode)
    (objc . objc-mode)
    (oberon2 . oberon-mode)
    (ocaml . tuareg-mode)
    (octave . octave-mode)
    (pascal . pascal-mode)
    (perl . perl-mode)
    (php . php-mode)
    (plsql . plsql-mode)
    (prolog . prolog-mode)
    (properties . conf-mode)
    (python . python-mode)
    (ruby . ruby-mode)
    (scheme . scheme-mode)
    (smalltalk . smalltalk-mode)
    (sql . sql-mode)
    (tcl . tcl-mode)
    (vb . visual-basic-mode)
    (xml . nxml-mode)
    (text . text-mode))
  "Explicit mapping from pastebin format_short names to major modes.
Prefer built-in modes; modes that are not installed fall back to
`text-mode' - see `get-mode'.")

(defvar pastebin--default-user nil
  "The default user begin used")

(defvar pastebin--local-buffer-paste nil
  "Every pastebin buffer has a paste object associated with it")
(make-variable-buffer-local 'pastebin--local-buffer-paste)
;; a paste buffer keeps its identity across major mode switches,
;; e.g. when you paste M-x <language>-mode in it
(put 'pastebin--local-buffer-paste 'permanent-local t)

(defvar pastebin--list-buffer-user nil
  "Every pastebin list buffer has a user object associated with it")
(make-variable-buffer-local 'pastebin--list-buffer-user)

(defvar pastebin--list-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d") 'pastebin-delete-paste-at-point)
    (define-key map (kbd "r") 'pastebin-list-buffer-refresh)
    (define-key map (kbd "f") 'pastebin-list-buffer-refresh-sort-by-format)
    (define-key map (kbd "t") 'pastebin-list-buffer-refresh-sort-by-title)
    (define-key map (kbd "k") 'pastebin-list-buffer-refresh-sort-by-key)
    (define-key map (kbd "D") 'pastebin-list-buffer-refresh-sort-by-date)
    (define-key map (kbd "p") 'pastebin-list-buffer-refresh-sort-by-private)
    map)
  "Key map for pastebin list buffer")

(defconst pastebin--raw-paste-url "https://pastebin.com/raw/"
  "Concatenate this with paste key to get the raw paste.
Note: this only serves public and unlisted pastes; private ones need
the authenticated API, see `paste-fetch'.")

;;
;; EIEIO Layer
;;

;; PASTE-USER class

(defclass pastebin--paste-user ()
  ((dev-key :initarg :dev-key "Your developer key from http://pastebin.com/api (sensitive)")
   (usr-key :initarg :usr-key "Your user key from pastebin - a bearer token, clear it with pastebin-logout")
   (password :initarg :password "Legacy clear text password, unbound after the first successful login")
   (password-auth-source :initarg :password-auth-source "Auth-source spec plist used to look the password up when the login happens")
   (password-function :initarg :password-function "Function returning the password, called when the login happens")
   (username :initarg :username "Your username")
   (paste-list :initarg :paste-list "The list of pastes for this user")
   (list-buffer :initarg :list-buffer "Done by do-list-buffer")
   (sort-by :initarg :sort-by "Order to sort :paste-list")
  )
  "Class representing a pastebin.com user")

(cl-defmethod is-logged ((user pastebin--paste-user))
  "Return true if user is logged in"
  (slot-boundp user 'usr-key))

(cl-defmethod fetch-list-xml ((user pastebin--paste-user))
  "Fetch the list of pastes as xml, and return that buffer.
Returns nil when the user has no pastes yet - the API answers
\"No pastes found.\" which is a normal state, not an error"
  (pastebin--with-user-key
   user
   (lambda (usr-key)
     (let ((params (concat "api_dev_key=" (oref user dev-key)
                           "&api_user_key=" usr-key
                           "&api_results_limit=" (format "%d" pastebin-default-paste-list-limit)
                           "&api_option=list")))
       (with-current-buffer (pastebin--url-retrieve-synchronously pastebin-post-request-paste-url
                                                                  "POST"
                                                                  params)
         (pastebin--strip-CRs)
         (goto-char (point-min))
         (if (looking-at-p "No pastes found.")
             (progn
               (kill-buffer (current-buffer))
               nil)
           (current-buffer)))))))

(cl-defmethod refresh-paste-list ((user pastebin--paste-user))
  "Set/Refresh paste-list attr from the pastes retrieved from pastebin.com.
The old list is kept when fetching or parsing fails, and malformed
entries are skipped instead of aborting the whole refresh. An empty
account publishes an empty list"
  (let ((list-buf (fetch-list-xml user))
        plist)
    (when list-buf
      (unwind-protect
          (with-current-buffer list-buf
            (goto-char (point-min))
            (let ((i (point-min)))
              (while (re-search-forward "</paste>" nil t)
                (let ((start i))
                  (setq i (point))
                  ;; both XML parsing and object conversion are guarded:
                  ;; a broken entry is skipped, not fatal
                  (condition-case err
                      (let* ((paste-sexp (xml-parse-region start i))
                             (p (pastebin--sexp-to-paste paste-sexp)))
                        (oset p user user)
                        (oset p last-fetched (float-time))
                        (setq plist (append plist (list p))))
                    (error
                     (message "Skipping malformed paste entry: %s" err))))))
            )
        (kill-buffer list-buf)))
    ;; atomic swap: publish the list only after a full parse
    (oset user paste-list plist)
    )
  )

(defmacro pastebin--sort-by-string-attr (user attr)
  "sort :paste-list by `attr' in reverse order"
  `(progn
     (unless (member ,attr '(:key :title :format_long :format_short :url :date :private))
      (error "pastebin--sort-by-string-attr attr is not in '(:key :title :format_long :format_short :url :date :private)"))

     (let ((attr-name (intern (substring (symbol-name ,attr) 1))))
       (oset ,user paste-list (sort (oref ,user paste-list) (lambda (p1 p2)
                                                            (string< (downcase (eieio-oref p1 attr-name))
                                                                     (downcase (eieio-oref p2 attr-name)))))))
     )
  )

(cl-defmethod do-list-buffer ((user pastebin--paste-user))
  "Create a buffer with a list of pastes and return it
Some keybinds are setted"
  (unless (is-logged user)
    (error "do-list-buffer called with unloged user"))

  (unless (slot-boundp user 'list-buffer)
    (oset user list-buffer (format "Pastebin %s pastes" (oref user username))))

  (unless (get-buffer (oref user list-buffer))
    (generate-new-buffer (oref user list-buffer))
    (message "%s buffer created" (oref user list-buffer)))

  (let ((inhibit-read-only t)
        old-point)
    (with-current-buffer (get-buffer (oref user list-buffer))

      (setq old-point (point))

      (erase-buffer)

      (widget-minor-mode 1)
      (use-local-map pastebin--list-map)

      (setq pastebin--list-buffer-user user)

      (widget-insert (format "%-4.4s | %-8.8s | %-32.32s | %-7.7s | %-24.24s\n"
                             "VIEW" "ID" "TITLE" "FORMAT" "DATE"))
      (dolist (paste (oref user paste-list))
        (widget-create 'link
                       :notify (lambda (_wid &rest _ignore)
                                 (pastebin--fetch-paste-at-point))
                       :paste paste
                       :follow-link t
                       :value (format "%-4.4s | %-8.8s | %-32.32s | %-7.7s | %-24.24s"
                                      (cond
                                       ((string= (oref paste private) "0")
                                        "PUBL")
                                       ((string= (oref paste private) "1")
                                        "ULST")
                                       ((string= (oref paste private) "2")
                                        "PRIV")
                                       (t
                                        "_ERR"))
                                      (oref paste key)
                                      (or (oref paste title) "")
                                      (oref paste format_short)
                                      (format-time-string "%c" (seconds-to-time (string-to-number (oref paste date))))
                                      )
                       )

        (widget-insert "\n")
        )
      (widget-setup)
      (goto-char (or old-point (point-min)))
      (current-buffer)
      ) ;; (with-current-buffer (get-buffer (oref user list-buffer))
    ) ;; (let ((inhibit-read-only t)
  )

(cl-defmethod login ((user pastebin--paste-user))
  "Log USER in on demand and return its user key
The password is only looked up when no `usr-key' is cached yet:
through `auth-source' (see `pastebin-create-login'), by calling
`password-function', or from the legacy `password' slot - which
gets unbound once the login succeeds"
  (if (slot-boundp user 'usr-key)
      (oref user usr-key)
    (let ((password (cond ((slot-boundp user 'password-auth-source)
                           (apply #'auth-source-pick-first-password
                                  (oref user password-auth-source)))
                          ((slot-boundp user 'password-function)
                           (funcall (oref user password-function)))
                          ((slot-boundp user 'password)
                           (oref user password))
                          (t
                           (error "pastebin login: no password configured")))))
      (unless (stringp password)
        (error "pastebin login: password provider did not return a string"))
      (let* ((params (concat "api_dev_key=" (oref user dev-key)
                             "&api_user_name=" (url-hexify-string (oref user username))
                             "&api_user_password=" (url-hexify-string password)))
             (resp-buf (pastebin--url-retrieve-synchronously pastebin-post-request-login-url
                                                             "POST"
                                                             params)))
        (unwind-protect
            (with-current-buffer resp-buf
              ;; trim: a trailing newline in the response would corrupt every
              ;; later request that carries api_user_key
              (let ((key (string-trim (buffer-substring-no-properties
                                       (point-min) (point-max)))))
                ;; a valid user key is a non-empty, whitespace-free token:
                ;; an empty or multi-word answer is an unrecognized error,
                ;; not a key - refuse it so the legacy password survives
                ;; for a retry
                (unless (and (not (string-empty-p key))
                             (not (string-match-p "[ \t\r\n\f]" key)))
                  (error "pastebin login: got no valid user key, check your credentials"))
                (oset user usr-key key)))
          (when (buffer-live-p resp-buf)
            (kill-buffer resp-buf)))
        ;; Burn the legacy password: once logged in it is useless. It is
        ;; kept when the login fails so the login can be retried
        (when (slot-boundp user 'password)
          (slot-makeunbound user 'password))
        (oref user usr-key)))))

(defun pastebin--stale-user-key-error-p (err)
  "Return non-nil when ERR blames the cached user key
These are pastebin's official answers for an unusable api_user_key:
\"Bad API request, invalid api_user_key\" and \"Bad API request,
invalid or expired api_user_key\". ERR is a condition-case error
description of either `pastebin-http-error' or `pastebin-api-error',
the response body sits in its third element"
  (and (memq (car err) '(pastebin-http-error pastebin-api-error))
       (stringp (nth 2 err))
       (string-match-p "Bad API request, invalid\\( or expired\\)? api_user_key"
                       (nth 2 err))))

(defun pastebin--with-user-key (user body)
  "Run BODY with the user key of USER, retrying once on stale keys
BODY receives the user key string and returns the request result.
When the request fails with an error that clearly blames the user
key - see `pastebin--stale-user-key-error-p' - the cached key is
dropped, USER logs in again and BODY runs once more with the fresh
key. Any other error, a second failure, or the absence of a usable
password source (a burnt legacy password) propagates the first
error untouched. BODY must build its request inside itself: the
retry needs the fresh key, replaying old parameters would not do"
  (let (retried)
    (catch 'pastebin--with-user-key-done
      (while t
        (condition-case err
            (throw 'pastebin--with-user-key-done
                   (funcall body (login user)))
          ((pastebin-http-error pastebin-api-error)
           (unless (and (not retried)
                        (pastebin--stale-user-key-error-p err)
                        (or (slot-boundp user 'password-auth-source)
                            (slot-boundp user 'password-function)
                            (slot-boundp user 'password)))
             (signal (car err) (cdr err)))
           (setq retried t)
           ;; the cached key is the stale one: drop it before logging
           ;; in again, `login' would just hand it right back
           (when (slot-boundp user 'usr-key)
             (slot-makeunbound user 'usr-key))
           (login user)))))))

(defun pastebin--paste-create (buffer-data &optional private expire-date guest)
  "Create a paste from BUFFER-DATA and kill its url.
PRIVATE and EXPIRE-DATE go to the submit call. When GUEST is
non-nil, create an anonymous paste: only the dev key is sent, no
login and no user key"
  (let ((user (pastebin--default-user-or-error)))
    (unless guest
      (unless (is-logged user)
        (login user)))
    (save-excursion
      (goto-char (point-min))
      (pastebin-mode 1)
      (let* ((pbuf (if guest
                       (pastebin--paste-submit (oref user dev-key) nil
                                               buffer-data private expire-date)
                     (paste-new user buffer-data private expire-date)))
             (url (pastebin--get-pst-url pbuf))
             (link-point (re-search-forward "https\\?://[A-Za-z0-9_-]+\\.[A-Za-z0-9]+" nil t)))
        (kill-buffer pbuf)
        (kill-new url)
        (message "URL: %s%s" url
                 (if link-point
                     (concat (format "\nYour buffer contains a URL at line %d\n" (line-number-at-pos link-point))
                             (format "pastebin may ask you to fill a captcha when you open it"))
                   ""))))))

(defconst pastebin--expire-date-options
  '(("N (never)" . "N")
    ("10M (ten minutes)" . "10M")
    ("1H (one hour)" . "1H")
    ("1D (one day)" . "1D")
    ("1W (one week)" . "1W")
    ("2W (two weeks)" . "2W")
    ("1M (one month)" . "1M")
    ("6M (six months)" . "6M")
    ("1Y (one year)" . "1Y"))
  "Friendly labels and official values for paste expiration dates.")

(defun pastebin--read-expire-date ()
  "Prompt for a paste expiration date and return its official value
RET picks the default, pastebin's never-expire value"
  (let ((choice (completing-read "Expire date: "
                                 pastebin--expire-date-options
                                 nil t nil nil
                                 (caar pastebin--expire-date-options))))
    (cdr (assoc choice pastebin--expire-date-options))))

(defun pastebin--private-from-prefix (prefix)
  "Map PREFIX to an authenticated pastebin privacy value
No prefix is public, C-u is unlisted, C-u C-u is private"
  (cond
   ((null prefix) "0")
   ((>= (prefix-numeric-value prefix) 16) "2")
   (t "1")))

(defun pastebin--normalize-private (private)
  "Return PRIVATE as one of pastebin's \"0\", \"1\" or \"2\" values
Nil and the old boolean form of the unlisted argument stay accepted
for callers of `paste-new' predating the private support. Privacy
must never be changed silently: anything else errors out"
  (cond
   ((member private '("0" "1" "2")) private)
   ((memq private '(nil 0)) "0")
   ((eq private t) "1")
   (t
    (error "Invalid Pastebin privacy value: %S" private))))

(defun pastebin--normalize-expire-date (expire-date)
  "Return EXPIRE-DATE, defaulting to pastebin's never-expire value"
  (let ((value (or expire-date "N")))
    (unless (member value (mapcar #'cdr pastebin--expire-date-options))
      (error "Invalid Pastebin expiration date: %S" value))
    value))

(defun pastebin--paste-submit (dev-key user-key buffer-data private expire-date)
  "Submit BUFFER-DATA using DEV-KEY and optional USER-KEY
USER-KEY nil creates a guest paste and omits api_user_key"
  (let* ((pprivate (pastebin--normalize-private private))
         (pexpire (pastebin--normalize-expire-date expire-date))
         (ptitle (buffer-name))
         (pbuffer (current-buffer)))
    (when (and (null user-key) (string= pprivate "2"))
      (error "Guest pastes cannot be private, they need a user key"))
    (let ((params (concat "api_dev_key=" dev-key
                          (if user-key
                              (concat "&api_user_key=" user-key)
                            "")
                          "&api_paste_name=" (url-hexify-string ptitle)
                          "&api_paste_format=" (url-hexify-string (pastebin--get-format-string-from-major-mode))
                          "&api_paste_code=" (url-hexify-string (with-current-buffer pbuffer
                                                                  buffer-data))
                          "&api_option=paste"
                          "&api_paste_private=" pprivate
                          "&api_paste_expire_date=" pexpire)))
      (with-current-buffer (pastebin--url-retrieve-synchronously pastebin-post-request-paste-url
                                                                 "POST"
                                                                 params)
        (current-buffer)))))

(cl-defmethod paste-new ((user pastebin--paste-user) buffer-data
                         &optional private expire-date)
  "Upload a new paste to pastebin.com
PRIVATE is \"0\" for public, \"1\" for unlisted and \"2\" for
private; nil and the old unlisted boolean stay accepted. EXPIRE-DATE
is one of pastebin's official values, \"N\" (never) by default"
  (pastebin--with-user-key
   user
   (lambda (usr-key)
     (pastebin--paste-submit (oref user dev-key) usr-key buffer-data
                             private expire-date))))



;; PASTE CLASS

(defclass pastebin--paste ()
  ((key :initarg :key)
   (date :initarg :date)
   (title :initarg :title)
   (size :initarg :size)
   (expire_date :initarg :expire_date)
   (private :initarg :private)
   (format_long :initarg :format_long)
   (format_short :initarg :format_short)
   (url :initarg :url)
   (buffer :initarg :buffer)
   (last-fetched :initarg :last-fetched)
   (user :initarg :user :type pastebin--paste-user)
   (hits :initarg :hits))
  "Class representing a paste from pastebin.com
The contents of paste are not stored. Instead the method
`paste-fetch' fetch and retrieve the buffer with paste contents")

(cl-defmethod get-mode ((p pastebin--paste))
  "Return the major mode matching the paste format.
Three levels: a known pastebin format wins when its mode is
installed; otherwise the paste title's file extension is matched
against `auto-mode-alist' - the same registry Emacs uses for files,
covering formats pastebin itself does not know (an uploaded
\"init.fish\" opens in `fish-mode' when that is installed). Falls
back to `text-mode': a missing or unknown format must never make
the paste unopenable"
  (let* ((format (and (slot-boundp p 'format_short)
                      (stringp (oref p format_short))
                      (intern (oref p format_short))))
         (format-mode (and format
                           (cdr (assq format pastebin--format-mode-alist))))
         (title (and (slot-boundp p 'title)
                     (stringp (oref p title))
                     (oref p title)))
         (title-mode (and title
                          (not (string-empty-p title))
                          (assoc-default title auto-mode-alist
                                         #'string-match-p))))
    (or (and format-mode
             (fboundp format-mode)
             ;; "text" and unknown formats leave the title a chance
             (not (eq format-mode 'text-mode))
             format-mode)
        (and (symbolp title-mode)
             (fboundp title-mode)
             title-mode)
        'text-mode)))

(cl-defmethod fetch-and-process ((p pastebin--paste))
  "Fetch buffer a do needed processing before switching to it"
  (with-current-buffer (paste-fetch p)
    (switch-to-buffer (current-buffer))))

(defun pastebin--fetch-private-paste-content (p)
  "Fetch the content of private paste P via the authenticated API.
The raw url only serves public and unlisted pastes; for private ones
the API `api_option=show_paste' with the user key is required."
  (let ((user (oref p user)))
    (pastebin--with-user-key
     user
     (lambda (usr-key)
       (let ((params (concat "api_dev_key=" (oref user dev-key)
                             "&api_user_key=" usr-key
                             "&api_paste_key=" (oref p key)
                             "&api_option=show_paste")))
         (pastebin--url-retrieve-synchronously pastebin-post-request-raw-url
                                               "POST"
                                               params))))))

(cl-defmethod paste-fetch ((p pastebin--paste))
  "Fetch the raw content from paste and return buffer containing"
  (let* ((content-buf (if (equal (oref p private) "2")
                          (pastebin--fetch-private-paste-content p)
                        (pastebin--url-retrieve-synchronously
                         (concat pastebin--raw-paste-url (oref p key))
                         "GET"
                         "")))
         (inhibit-read-only t)
         (pbuf (if (and (slot-boundp p 'buffer)
                        (buffer-live-p (oref p buffer)))
                   (oref p buffer)
                 ;; generate-new-buffer: never erase an existing user
                 ;; buffer that happens to share the paste title
                 (oset p buffer
                       (generate-new-buffer
                        (format "*paste: %s*" (or (oref p title) "UNTITLED")))))))
    (with-current-buffer pbuf
      (erase-buffer)
      (insert-buffer-substring content-buf)
      (kill-buffer content-buf)
      (pastebin--strip-paste-CRs)
      (funcall (get-mode p))
      (setq pastebin--local-buffer-paste p) ;; buffer local
      (pastebin-mode 1)
      (current-buffer))))

(cl-defmethod paste-delete ((p pastebin--paste))
  "Detele paste from pastebin.com"
  (unless (and (slot-boundp p 'user)
               (slot-boundp p 'key)
               (slot-boundp (oref p user) 'dev-key)
               (slot-boundp (oref p user) 'usr-key))
    (error "paste-delete called with ubound slot object"))

  (let ((user (oref p user)))
    (pastebin--with-user-key
     user
     (lambda (usr-key)
       (let* ((params (concat "api_dev_key=" (oref user dev-key)
                              "&api_user_key=" usr-key
                              "&api_paste_key=" (oref p key)
                              "&api_option=delete"))
              (resp-buf (pastebin--url-retrieve-synchronously pastebin-post-request-paste-url
                                                              "POST"
                                                              params)))
         (with-current-buffer resp-buf
           (prog1 (buffer-string) ;; Pastebin send somthing like paste xxx deleted
             (kill-buffer resp-buf))))))))

;; Local functions and helpers

(defun pastebin--get-format-string-from-major-mode ()
  "Returns the format string from major mode
Error if major-mode is nil"
  (unless major-mode
    (error "pastebin--get-format-string-from-major-mode called with nil major-mode"))
  (or (cdr (assoc major-mode pastebin--type-assoc))
      "text"))

(defun pastebin--sexp-get-attr-h (paste-sexp attr &optional onerror)
  "Return the attribute `attr' from `paste-sexp'
If onerror is given (should be a string) is used when no such attribute
is found.
Attributes are described here: http://pastebin.com/api#9
`attr' must be a symbol
Ex: (pastebin-paste-get-attr some-paste-sexp \\='paste_tittle)"
  (unless (symbolp attr)
    (error "attr should be a symbol"))
  (when (and onerror
             (not (stringp onerror)))
    (error "onerror should be a string"))
  (let ((a (or (car (last (assoc attr (nthcdr 2 (car paste-sexp)))))
               onerror)))
    (unless a
      (error "No attribute %s on paste sexp '%s'" attr paste-sexp))
    (format "%s" a)))

(defun pastebin--strip-paste-CRs (&optional buffer)
  "Get rid of CR
I use this after fetching a paste to get rid of annoying ^M"
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (re-search-forward "\r" nil t)
        (replace-match ""))
      buffer)))

(defun pastebin--strip-CRs (&optional buffer)
  "Get rid of CRLF
I need this for xml-parse-region reponse without getting
a lot of spaces and CRLF on pastes sexps. See `pastebin--sexp-to-paste'"
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (re-search-forward "\r\n" nil t)
        (replace-match ""))
      buffer)))

(defun pastebin--strip-http-header (&optional buffer)
  "Given a buffer with an HTTP response, remove the header and return the buffer
If no buffer is given current buffer is used"
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (goto-char (point-min))
      ;; tolerate a missing header separator: the status check decides
      ;; how such a malformed response fails, not a cryptic search error
      (when (re-search-forward "\n\n" nil t)
        ;; delete-region, not kill-region: response headers must not end
        ;; up on the kill-ring
        (delete-region (point-min) (point))))
    buffer))

(defun pastebin--get-paste-at-point ()
  "Get the paste at point at current-buffer"
  (let ((wid (widget-at)))
    (if (not wid)
        (error "No paste at point")
      (widget-get wid :paste))))

(defun pastebin--fetch-paste-at-point ()
  "Fetch and switch to paste at point"
  (let ((p (pastebin--get-paste-at-point)))
    (fetch-and-process p)))

(defun pastebin--sexp-to-paste (paste-sexp)
  "Construct a `pastebin--paste' object from PASTE-SEXP.
PASTE-SEXP is an sexp returned from `xml-parse-region' on a
pastebin.com response. See `fetch-list-xml' for more information"
  (unless (consp paste-sexp)
    (error "pastebin--sexp-to-paste called without cons type"))
  (condition-case err
      (pastebin--paste :key (pastebin--sexp-get-attr-h paste-sexp 'paste_key)
                       :date (pastebin--sexp-get-attr-h paste-sexp 'paste_date)
                       :title (pastebin--sexp-get-attr-h paste-sexp 'paste_title "UNTITLED")
                       :size (pastebin--sexp-get-attr-h paste-sexp 'paste_size)
                       :expire_date (pastebin--sexp-get-attr-h paste-sexp 'paste_expire_date)
                       :private (pastebin--sexp-get-attr-h paste-sexp 'paste_private)
                       :format_long (pastebin--sexp-get-attr-h paste-sexp 'paste_format_long)
                       :format_short (pastebin--sexp-get-attr-h paste-sexp 'paste_format_short)
                       :url (pastebin--sexp-get-attr-h paste-sexp 'paste_url)
                       )
    ((debug error)
     (error "Cant construct paste from sexp %s\nError: %s" paste-sexp err))))

(defun pastebin--url-retrieve-synchronously (url method params)
  "Retrieve a buffer from pastebin, raising an error if an error ocurr"
  (unless (stringp url)
    (error "pastebin--url-retrieve-synchronously `url' need to be a string"))

  (unless (stringp method)
    (error "pastebin--url-retrieve-synchronously `method' need to be a string"))

  (unless (stringp params)
    (error "pastebin--url-retrieve-synchronously `params' need to be a string"))

  (let* ((inhibit-read-only t)
         (url-request-method method)
         (url-request-extra-headers
          '(("Content-Type" . "application/x-www-form-urlencoded")))
         (url-request-data params)
         (content-buf (url-retrieve-synchronously url))
         done)
    (unwind-protect
        (progn
          (let ((status (pastebin--http-status content-buf)))
            (with-current-buffer content-buf
              (goto-char (point-min))
              (pastebin--strip-http-header)
              ;; url hands the body over as raw bytes, but pastebin
              ;; speaks utf-8: decode them so every consumer gets
              ;; characters. bytes that are not valid utf-8 survive as
              ;; raw-byte characters instead of failing the request
              (let ((decoded (decode-coding-string (buffer-string) 'utf-8)))
                (erase-buffer)
                (set-buffer-multibyte t)
                (insert decoded)))
            (unless (and status (>= status 200) (< status 300))
              ;; Pastebin reports API errors on non-2xx responses, the reason
              ;; is in the decoded body: surface it instead of a generic message
              (let ((body (with-current-buffer content-buf
                            (string-trim (buffer-string)))))
                (signal 'pastebin-http-error
                        (list (format "pastebin--url-retrieve-synchronously HTTP %s: %.300s"
                                      (or status "malformed") body)
                              (with-current-buffer content-buf
                                (buffer-string)))))))
          (with-current-buffer content-buf
            (pastebin--error-if-bad-response (current-buffer))) ;; two `with-current-buffer' on same buffer :-/ slow
          (setq done t)
          content-buf) ;; return the buffer
      ;; success hands the buffer to the caller, keep it alive; on any
      ;; other exit path - HTTP errors, pastebin API errors on a 2xx
      ;; status, errors while parsing the status line - clean it up
      (unless done
        (when (buffer-live-p content-buf)
          (kill-buffer content-buf))))))

(defun pastebin--error-if-bad-response (buf)
  "Raises a error if is a bad response from pastebin"
  (unless (or (bufferp buf)
              (stringp buf))
    (error "pastebin--bad-presponse-p `buf' need be a buffer or a string"))

  (with-current-buffer buf
    ;; search the whole body: the point position at call time must not
    ;; decide what gets checked
    (goto-char (point-min))
    (if (or
         (save-excursion
           (re-search-forward "Bad API request," nil t))
         (save-excursion
           (re-search-forward "URL Post limit, maximum pastes per 24h reached" nil t)))
        (let ((body (buffer-string)))
          (signal 'pastebin-api-error
                  (list (format "Pastebin bad response: %s" body) body)))
      nil)))


(defun pastebin--http-status (header-buf)
  "Return the HTTP status code of the response in HEADER-BUF, or nil"
  (unless (bufferp header-buf)
    (error "pastebin--http-status: `header-buf' need be a buffer :/"))

  (with-current-buffer header-buf
    (save-excursion
      (goto-char (point-min))
      (and (re-search-forward "HTTP/[0-9.]+ +\\([0-9][0-9][0-9]\\)" nil t)
           (string-to-number (match-string 1))))))

(defun pastebin--get-pst-url (buf)
  "Return url string from buf"
  (unless (and (or (bufferp buf)
                   (stringp buf))
                (get-buffer buf))
     (error (concat "pastebin--get-pst-url `buf' need\n"
                    "be a existing buffer or buffer name as string")))

  (with-current-buffer buf
    (save-excursion
      (buffer-substring-no-properties (point-min) (point-max)))))

;; User interface

(defun pastebin--default-user-or-error ()
  "Return `pastebin--default-user', erroring when login is not configured"
  (or pastebin--default-user
      (user-error "No pastebin user configured, call `M-x pastebin-create-login' first")))

(defun pastebin-show-url ()
  "On a buffer from a fetched paste, show the url o echo area"
  (interactive)
  (if pastebin--local-buffer-paste
      (message (format "Paste URL: %s" (oref pastebin--local-buffer-paste url)))
    (message (format "Current buffer is not a paste buffer"))))

(defun pastebin-list-buffer-refresh ()
  "Refresh the list buffer screen
Operates on current buffer"
  (interactive)
  (let ((user (pastebin--default-user-or-error)))
    (unless (is-logged user)
      (login user))
    (refresh-paste-list user)
    (switch-to-buffer (do-list-buffer user))
    (message "%d pastes fetched!" (length (oref user paste-list))))
  )

(defun pastebin-logout ()
  "Forget the cached user key of the default pastebin user
The user key is a bearer token, this drops it from memory. The next
API call will log in again, asking the password source for a password.
Note: the legacy :password channel is consumed by the first login -
after a logout it needs `pastebin-create-login' again"
  (interactive)
  (if (and pastebin--default-user
           (slot-boundp pastebin--default-user 'usr-key))
      (progn
        (slot-makeunbound pastebin--default-user 'usr-key)
        (message "Pastebin user key cleared"))
    (message "No pastebin user is logged in")))


(defun pastebin-list-buffer-refresh-sort-by-title ()
  (interactive)
  (pastebin--sort-by-string-attr pastebin--default-user :title)
  (switch-to-buffer (do-list-buffer pastebin--default-user))
  )

(defun pastebin-list-buffer-refresh-sort-by-format ()
  (interactive)
  (pastebin--sort-by-string-attr pastebin--default-user :format_short)
  (switch-to-buffer (do-list-buffer pastebin--default-user))
  )

(defun pastebin-list-buffer-refresh-sort-by-key ()
  (interactive)
  (pastebin--sort-by-string-attr pastebin--default-user :key)
  (switch-to-buffer (do-list-buffer pastebin--default-user))
  )

(defun pastebin-list-buffer-refresh-sort-by-date ()
  (interactive)
  (pastebin--sort-by-string-attr pastebin--default-user :date)
  (oset pastebin--default-user paste-list (reverse (oref pastebin--default-user paste-list)))
  (switch-to-buffer (do-list-buffer pastebin--default-user))
  )

(defun pastebin-list-buffer-refresh-sort-by-private ()
  (interactive)
  (pastebin--sort-by-string-attr pastebin--default-user :private)
  (switch-to-buffer (do-list-buffer pastebin--default-user))
  )

(defun pastebin-delete-paste-at-point ()
  "Delete the paste at point"
  (interactive)
  (let ((p (pastebin--get-paste-at-point)))
    (when (y-or-n-p (format "Do you really want to delete paste %s from %s\n"
                            (oref p title)
                            (format-time-string "%c" (seconds-to-time (string-to-number (oref p date))))))
      (message "%s" (paste-delete p))
      (pastebin-list-buffer-refresh))))

(defun pastebin-new (p)
  "Create a new paste from buffer
No prefix makes it public, C-u makes it unlisted and C-u C-u makes
it private. The command asks for the paste expiration date"
  (interactive "P")
  (pastebin--paste-create (buffer-string)
                          (pastebin--private-from-prefix p)
                          (pastebin--read-expire-date)))

(defun pastebin-new-from-selection (start end &optional p)
  "Create a new paste from buffer selection
The prefix and the expiration prompt work as in `pastebin-new'"
  (interactive (list (region-beginning) (region-end) current-prefix-arg))
  (pastebin--paste-create (buffer-substring-no-properties start end)
                          (pastebin--private-from-prefix p)
                          (pastebin--read-expire-date)))

(defun pastebin-new-guest (p)
  "Create an anonymous paste from buffer, no login needed
No prefix makes it public and any prefix makes it unlisted; guest
pastes cannot be private. The command asks for the paste expiration
date. Only the configured dev key is sent, no user key"
  (interactive "P")
  (pastebin--paste-create (buffer-string)
                          (if p "1" "0")
                          (pastebin--read-expire-date)
                          t))

(defun pastebin-create-login (&rest args)
  "Create a login data. The effective login will be done when needed
`args' is a keyword list. :username and :dev-key are required strings.
Exactly one password source must be given:

  :password-auth-source  plist spec passed to `auth-source-pick-first-password'
                         when the login happens, e.g.
                         \='(:host \"pastebin.com\" :user \"YOURUSER\")
  :password-function     function called with no arguments when the login
                         happens, returning the password as a string
  :password              legacy plain string, kept in memory until the
                         first successful login clears it"
  ;; Keyword arguments work arround
  ;; I want to get rid of cl dependence here
  (let* ((missing (make-symbol "missing"))
         (username missing)
         (dev-key missing)
         (password-auth-source missing)
         (password-function missing)
         (password missing))
    (while args
      (let ((key (pop args))
            value)
        (unless (memq key '(:username :dev-key :password-auth-source
                            :password-function :password))
          (error "pastebin-create-login: unknown keyword %s" key))
        (if args
            (setq value (pop args))
          (error "pastebin-create-login: missing value for %s" key))
        (cond ((eq key :username)             (setq username value))
              ((eq key :dev-key)              (setq dev-key value))
              ((eq key :password-auth-source) (setq password-auth-source value))
              ((eq key :password-function)    (setq password-function value))
              ((eq key :password)             (setq password value)))))
    ;; Function body
    (unless (and (stringp username) (stringp dev-key))
      (error "pastebin-create-login argument missing or not a string. (username or dev-key)"))
    (unless (= 1 (+ (if (eq password-auth-source missing) 0 1)
                    (if (eq password-function missing) 0 1)
                    (if (eq password missing) 0 1)))
      (error "pastebin-create-login: give exactly one of :password-auth-source, :password-function or :password"))
    (cond
     ;; This channel exists to keep clear text passwords out of the user
     ;; object: refuse specs that embed a secret value
     ((not (eq password-auth-source missing))
      (unless (and (listp password-auth-source)
                   (zerop (% (length password-auth-source) 2))
                   (not (plist-member password-auth-source :secret))
                   (not (plist-member password-auth-source :password)))
        (error "pastebin-create-login: :password-auth-source must be a plist spec without :secret/:password, like '(:host \"pastebin.com\" :user \"YOURUSER\")")))
     ((not (eq password-function missing))
      (unless (functionp password-function)
        (error "pastebin-create-login: :password-function must be a function")))
     (t
      (unless (stringp password)
        (error "pastebin-create-login: :password must be a string"))))
    (setq pastebin--default-user
          (cond ((not (eq password-auth-source missing))
                 (pastebin--paste-user :username username
                                       :dev-key dev-key
                                       :password-auth-source password-auth-source))
                ((not (eq password-function missing))
                 (pastebin--paste-user :username username
                                       :dev-key dev-key
                                       :password-function password-function))
                (t
                 (pastebin--paste-user :username username
                                       :dev-key dev-key
                                       :password password))))
    (message "User %s created, login is on demand. Have a nice day!" username)
    ) ;; (let* ((missing ...
  ) ;; (defun pastebin-create-login &rest args)

;; Setup minor mode keymap
(or (assq 'pastebin-mode minor-mode-map-alist)
    (setq minor-mode-map-alist (cons (cons 'pastebin-mode pastebin--mode-map)
                                     minor-mode-map-alist)))

(provide 'neopastebin)

;;; END of neopastebin

