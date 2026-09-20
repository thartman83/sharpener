;;; sharpener-snippets.el --- Yasnippet integration for sharpener -*- lexical-binding: t; -*-

;; Author: Tom Hartman
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (yasnippet "0.14.0"))
;; Keywords: languages, tools, dotnet, csharp

;;; Commentary:

;; Bridges sharpener's bundled templates to yasnippet.  Registers the
;; shipped snippets/ tree into `yas-snippet-dirs', expands named snippets
;; into freshly created files (`sharpener-expand-into-file'), and
;; provides the `sharpener-yas--*' API that the snippet bodies call
;; through embedded elisp to infer namespaces and type names.
;;
;; Kept separate from sharpener-util so the discovery/inference layer
;; carries no yasnippet dependency.

;;; Code:

(require 'sharpener-util)

;;;; Yasnippet integration

;; The templates ship as real yasnippet files under snippets/, keyed by
;; major mode.  Two consequences:
;;   1. Registering the directory in `yas-snippet-dirs' makes them
;;      available for ordinary interactive expansion (type "class" TAB in
;;      a .cs buffer).
;;   2. A user's own snippet with the same name in an earlier
;;      `yas-snippet-dirs' entry shadows ours -- so customization is done
;;      by overriding, never by editing this package.
;;
;; The scaffolder expands these same snippets into freshly created files
;; via `sharpener-expand-into-file' below, so there is one source of
;; truth for each template.
;;
;; The `sharpener-yas--*' helpers are the API the snippet bodies call
;; through embedded `(...)` elisp.  They read the *target file's* context
;; (its directory, the enclosing project) rather than wherever point
;; happened to be, which is what makes namespace inference correct when a
;; snippet is expanded into a new file.

(declare-function yas-lookup-snippet "yasnippet" (name &optional mode noerror))
(declare-function yas-expand-snippet "yasnippet" (content &optional start end expand-env))
(declare-function yas-minor-mode "yasnippet" (&optional arg))
(declare-function yas-reload-all "yasnippet" (&optional no-jit interactive))
(declare-function yas-load-directory "yasnippet" (top-level-dir &optional use-jit interactive))

;; Forward declaration so the byte-compiler knows this is a special
;; variable defined by yasnippet at runtime; avoids a free-variable
;; warning without loading yasnippet at compile time.
(defvar yas-snippet-dirs)

(defun sharpener--this-file ()
  "Return the absolute path of this source file, however it was loaded.
`load-file-name' is only bound while a file is being loaded, and is
nil under eval, some batch `-l' paths, and after a `.elc' load -- so
relying on it alone leaves `sharpener--snippets-dir' nil.  Fall back
through `buffer-file-name' (interactive eval) and finally
`locate-library', which searches `load-path' for the feature and does
not depend on being inside a load at all."
  (or load-file-name
      buffer-file-name
      (locate-library "sharpener-snippets")))

(defun sharpener--compute-snippets-dir ()
  "Compute the bundled snippets directory from this file's location.
This file lives in lisp/; the snippets/ tree ships at the package
root, one level up.  Returns nil only if the file's own path cannot be
determined by any means, which should not happen for an installed or
loaded package."
  (when-let* ((self (sharpener--this-file)))
    (expand-file-name
     "snippets"
     (file-name-directory
      (directory-file-name (file-name-directory self))))))

(defvar sharpener--snippets-dir (sharpener--compute-snippets-dir)
  "Directory holding sharpener's bundled yasnippet templates.
Computed via `sharpener--compute-snippets-dir'.  If it ever comes back
nil (path undeterminable at load), `sharpener-register-snippets'
recomputes it, so a later call can still succeed.")

;;;###autoload
(defun sharpener--add-snippets-dir ()
  "Ensure `sharpener--snippets-dir' is present in `yas-snippet-dirs'.
Normalizes `yas-snippet-dirs' to a list first (yasnippet permits a bare
string), then appends ours if absent so user dirs keep precedence.
Idempotent: calling repeatedly leaves exactly one entry.  Persisting the
dir here -- rather than only loading it -- is what lets our snippets
survive a later `yas-reload-all', which rebuilds tables from this list."
  (when (boundp 'yas-snippet-dirs)
    (when (stringp yas-snippet-dirs)
      (setq yas-snippet-dirs (list yas-snippet-dirs)))
    (add-to-list 'yas-snippet-dirs sharpener--snippets-dir t)))

(defun sharpener-register-snippets ()
  "Add sharpener's bundled snippets to yasnippet and load them.
Works regardless of load order:
- If yasnippet is already loaded, the dir is added and loaded now.
- If not, the work is deferred via `with-eval-after-load' and runs when
  yasnippet loads.
The dir is persisted in `yas-snippet-dirs' (not merely loaded into the
tables), so a subsequent `yas-reload-all' re-includes our snippets.

If `sharpener--snippets-dir' is nil because the path could not be
determined at load time, recompute it here -- by the time this is
called the library is on `load-path', so `locate-library' resolves."
  (unless sharpener--snippets-dir
    (setq sharpener--snippets-dir (sharpener--compute-snippets-dir)))
  (when sharpener--snippets-dir
    (with-eval-after-load 'yasnippet
      (sharpener--add-snippets-dir)
      ;; Load just our dir into the tables. Pass nil for use-jit so the
      ;; tables are built EAGERLY -- with JIT loading, the templates are
      ;; not materialized until the mode is activated in a buffer, so an
      ;; immediate `yas-lookup-snippet' (and any batch/programmatic use)
      ;; finds nothing. Eager load is what makes lookup work right away.
      (when (fboundp 'yas-load-directory)
        (yas-load-directory sharpener--snippets-dir nil)))))

(defun sharpener-expand-into-file (snippet-name mode)
  "Expand the yasnippet named SNIPPET-NAME (for MODE) into the current buffer.
The buffer is assumed to be a freshly created, empty file buffer whose
major mode is already set.  Returns non-nil on success.

Ensures our snippets are registered and eagerly loaded before lookup,
so this works even if a prior `yas-reload-all' left them JIT-deferred
or if registration never ran -- the scaffolder calls this
programmatically and cannot rely on a mode-activation having triggered
a lazy load."
  (require 'yasnippet)
  (sharpener-register-snippets)
  (let ((template (yas-lookup-snippet snippet-name mode t)))
    (unless template
      ;; Lookup missed: force an eager load of our dir and retry once,
      ;; in case a JIT reload elsewhere deferred the templates.
      (when (and sharpener--snippets-dir (fboundp 'yas-load-directory))
        (yas-load-directory sharpener--snippets-dir nil)
        (setq template (yas-lookup-snippet snippet-name mode t))))
    (unless template
      (user-error "No sharpener snippet named %S for %s" snippet-name mode))
    (unless (bound-and-true-p yas-minor-mode)
      (yas-minor-mode 1))
    (yas-expand-snippet template)
    t))

;;;; Snippet-body API (called from within snippet templates)

;; During expansion these read from the buffer being expanded into, whose
;; `default-directory' is the target file's directory -- so the existing
;; inference helpers Just Work without extra plumbing.

(defun sharpener-yas--type-name (&optional prefix)
  "Return a default type name derived from the current buffer's file.
When PREFIX is non-nil and the base name does not already start with
it, prepend it (used to make interfaces default to an I-prefix)."
  (let* ((base (if buffer-file-name
                   (file-name-base buffer-file-name)
                 "MyType")))
    (if (and prefix (not (string-prefix-p prefix base)))
        (concat prefix base)
      base)))

(defun sharpener-yas--namespace-plain ()
  "Return the inferred namespace string for the current buffer."
  (sharpener-default-namespace default-directory))

(defun sharpener-yas--namespace-open ()
  "Return the opening namespace declaration for the current buffer.
File-scoped for net6.0+, block-scoped otherwise.  For block-scoped the
member body is not indented here -- yasnippet's own indentation
handling (`yas-indent-line') manages that."
  (let ((ns (sharpener-default-namespace default-directory)))
    (if (sharpener--file-scoped-namespace-supported-p)
        (format "namespace %s;\n\n" ns)
      (format "namespace %s\n{\n" ns))))

(defun sharpener-yas--namespace-close ()
  "Return the closing brace for a block-scoped namespace, or empty string."
  (if (sharpener--file-scoped-namespace-supported-p) "" "\n}"))

(defun sharpener-yas--titleize (text)
  "Turn a PascalCase TEXT into a spaced title for display."
  (let* ((case-fold-search nil)
         (spaced (replace-regexp-in-string
                 "\\([a-z0-9]\\)\\([A-Z]\\)" "\\1 \\2" text)))
    (if (string-empty-p spaced) "Page" spaced)))

(provide 'sharpener-snippets)
;;; sharpener-snippets.el ends here
