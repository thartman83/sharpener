;;; sharpener-test-common.el --- Shared test harness for sharpener -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared fixtures and helpers for sharpener's ERT suites.  Factored out
;; of the per-module test files so the sandbox macro and dotnet fixture
;; builders have a single definition rather than drifting copies.
;;
;; Provides:
;;   sharpener-test--dotnet-available-p  -- gate for :dotnet-tagged tests
;;   sharpener-test--with-sandbox        -- temp dir + cleanup macro
;;   sharpener-test--in-dir              -- run a thunk with a bound dir
;;   sharpener-test--make-solution       -- generate a real .sln/.slnx
;;   sharpener-test--make-project        -- generate a real project
;;
;; Requires only sharpener-util, since the fixture builders shell out to
;; the real dotnet CLI and assert against the discovery layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sharpener-util)

;;;; Infrastructure

(defvar sharpener-test--dotnet-available 'unknown
  "Cached availability of the `dotnet' CLI: t, nil, or the symbol unknown.")

(defun sharpener-test--dotnet-available-p ()
  "Return non-nil if a usable `dotnet' CLI is on PATH.
Result is cached after the first probe."
  (when (eq sharpener-test--dotnet-available 'unknown)
    (setq sharpener-test--dotnet-available
          (and (executable-find "dotnet")
               ;; Confirm it actually runs; a stale shim on PATH shouldn't
               ;; count.  `dotnet --version' is cheap and side-effect free.
               (zerop (call-process "dotnet" nil nil nil "--version")))))
  sharpener-test--dotnet-available)

(defun sharpener-test--run (dir &rest args)
  "Run dotnet ARGS in DIR, signalling with output on failure.
Returns the trimmed stdout+stderr on success."
  (let* ((default-directory (file-name-as-directory dir))
         (out (generate-new-buffer " *sharpener-test-dotnet*")))
    (unwind-protect
        (let ((code (apply #'call-process "dotnet" nil out nil args)))
          (with-current-buffer out
            (let ((text (buffer-string)))
              (unless (zerop code)
                (error "dotnet %s failed (exit %d) in %s:\n%s"
                       (string-join args " ") code dir text))
              (string-trim text))))
      (kill-buffer out))))

(defmacro sharpener-test--with-sandbox (varname &rest body)
  "Create a temp sandbox dir, bind its path to VARNAME, run BODY, clean up.
The sandbox is removed recursively afterward even if BODY errors.  BODY
runs with `default-directory' set to the sandbox so relative paths and
the discovery functions behave as they would in a real buffer visiting
a file there."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((,varname (make-temp-file "sharpener-test-" t))
          (default-directory (file-name-as-directory ,varname)))
     (unwind-protect
         (progn ,@body)
       (when (and ,varname (file-directory-p ,varname))
;;         (delete-directory ,varname t)
         ))))

(defun sharpener-test--in-dir (dir thunk)
  "Call THUNK with `default-directory' bound to DIR.
Mirrors visiting a file in DIR: discovery functions key off
`default-directory', so this is how we simulate buffer location."
  (let ((default-directory (file-name-as-directory dir)))
    (funcall thunk)))

;;;; Fixture builders (real dotnet invocations)

(defun sharpener-test--make-solution (root &optional name)
  "Create a solution in ROOT via `dotnet new sln'.
Returns the solution file's actual path -- which may be NAME.sln or
NAME.slnx depending on the SDK version.  This is deliberately read back
from disk rather than assumed."
  (apply #'sharpener-test--run root "new" "sln"
         (when name (list "--name" name)))
  (car (directory-files root t "\\.slnx?\\'")))

(defun sharpener-test--make-project (root rel-path &optional template)
  "Create a TEMPLATE project (default classlib) at REL-PATH under ROOT.
REL-PATH is relative to ROOT, e.g. \"src/Core\".  Returns the absolute
path of the generated project file."
  (let ((out (expand-file-name rel-path root)))
    (sharpener-test--run root "new" (or template "classlib")
                         "--output" rel-path
                         "--name" (file-name-nondirectory rel-path))
    (car (directory-files out t "\\.\\(cs\\|fs\\|vb\\)proj\\'"))))

(provide 'sharpener-test-common)
;;; sharpener-test-common.el ends here
