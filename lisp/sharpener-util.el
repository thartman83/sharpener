;;; sharpener-util.el --- Core utilities for sharpener -*- lexical-binding: t; -*-

;; Author: Tom Hartman
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, tools, dotnet, csharp

;;; Commentary:

;; Foundation layer for sharpener: project/solution discovery, C#
;; namespace inference, MSBuild property reading, and the
;; `sharpener-run-command' process primitive.  This file has no
;; dependencies beyond built-in subr-x, so it can be required by any
;; other sharpener module without pulling in transient or yasnippet.
;;
;; The package-wide `defgroup sharpener' lives here, at the foundation,
;; so every `defcustom' in higher layers has its group defined before it
;; loads.

;;; Code:

(require 'subr-x)

(defgroup sharpener nil
  "Scaffolding and file generation for .NET projects."
  :group 'tools
  :prefix "sharpener-")

(defcustom sharpener-output-buffer-name "*dotnet-output*"
  "Name of the buffer used for `dotnet' command output."
  :type 'string
  :group 'sharpener)

(defcustom sharpener-file-header-style 'none
  "Style of file header comment to insert at the top of generated files.
One of:
  none    - no header
  minimal - a single-line comment with the file name"
  :type '(choice (const :tag "None" none)
                 (const :tag "Minimal" minimal))
  :group 'sharpener)

(defcustom sharpener-save-after-scaffold nil
  "Whether to save generated files to disk immediately after expansion.
When nil (the default), a generator leaves a modified buffer visiting
the new file with the snippet's tab fields live, matching the ordinary
Emacs/yasnippet experience -- you fill the fields and save yourself.
When non-nil, the file is written to disk right after expansion,
matching Visual Studio's \"Add New Item\" behavior, so the file exists
on disk immediately (visible to dotnet, `dotnet sln add', and any other
external tooling).

Generators accept a per-call override, so this custom only sets the
default policy."
  :type 'boolean
  :group 'sharpener)

(defcustom sharpener-create-missing-dirs t
  "Whether to create missing intermediate directories when scaffolding.
When non-nil (the default), a generator whose target path includes a
not-yet-existing directory creates it.  When nil, a missing directory
is treated as a guard: interactively the generator prompts before
creating it (surfacing this option), and non-interactively it signals
an error rather than silently spawning directories.

Generators accept a per-call override, so this custom only sets the
default policy."
  :type 'boolean
  :group 'sharpener)

;;;; Policy resolution

;; Scaffolding side effects (saving the file, creating directories) are
;; each governed by a defcustom default plus an optional per-call
;; override.  The override uses a three-state convention: the symbol
;; `default' means "consult the custom", while t or nil force the
;; behavior on or off regardless of the custom.  This lets a caller --
;; notably the test suite -- force a behavior deterministically without
;; let-binding global state, and lets a caller force a behavior OFF even
;; when the custom defaults it on.

(defun sharpener-resolve-policy (override custom-value)
  "Resolve a three-state OVERRIDE against CUSTOM-VALUE.
OVERRIDE is the symbol `default' (meaning: use CUSTOM-VALUE) or a
boolean that overrides it.  Returns the effective boolean."
  (if (eq override 'default) custom-value override))

;;;; Root and project discovery

(defun sharpener--find-file-up (regexp &optional start)
  "Search upward from START (default `default-directory') for REGEXP.
Return the directory containing the first matching file, or nil."
  (let ((dir (locate-dominating-file
              (or start default-directory)
              (lambda (d)
                (directory-files d nil regexp t)))))
    (and dir (expand-file-name dir))))

(defun sharpener-solution-root ()
  "Return the solution root for the current buffer.
Prefers the directory of the nearest .sln/.slnx file; falls back to
the nearest directory containing a project file, then to
`default-directory'."
  (or (sharpener--find-file-up "\\.slnx?\\'")
      (sharpener--find-file-up "\\.\\(cs\\|fs\\|vb\\)proj\\'")
      (expand-file-name default-directory)))

(defun sharpener-project-root (&optional start)
  "Return the nearest project (.csproj/.fsproj/.vbproj) directory, or nil.
Search upward from START, defaulting to `default-directory'."
  (sharpener--find-file-up "\\.\\(cs\\|fs\\|vb\\)proj\\'" start))

(defun sharpener--project-file (&optional start)
  "Return the path of the nearest project file, or nil.
Search upward from START, defaulting to `default-directory'."
  (when-let* ((root (sharpener-project-root start))
              (matches (directory-files
                        root t "\\.\\(cs\\|fs\\|vb\\)proj\\'")))
    (car matches)))

(defun sharpener--root-namespace (&optional start)
  "Return the RootNamespace for the nearest project.
Reads an explicit <RootNamespace> from the project file if present,
otherwise derives it from the project file's base name.  Search upward
from START, defaulting to `default-directory'.  Returns nil if no
project can be found."
  (when-let* ((proj (sharpener--project-file start)))
    (or (sharpener--read-msbuild-property proj "RootNamespace")
        (file-name-base proj))))

(defun sharpener--read-msbuild-property (project-file property)
  "Return the value of MSBuild PROPERTY in PROJECT-FILE, or nil.
This is a lightweight regexp read, not a full XML parse -- adequate
for the simple <Property>value</Property> case that dominates SDK-style
projects."
  (when (file-readable-p project-file)
    (with-temp-buffer
      (insert-file-contents project-file)
      (goto-char (point-min))
      (when (re-search-forward
             (format "<%s>\\([^<]+\\)</%s>"
                     (regexp-quote property) (regexp-quote property))
             nil t)
        (string-trim (match-string 1))))))

;;;; Namespace inference

(defun sharpener--sanitize-namespace-segment (segment)
  "Turn SEGMENT (a path component) into a valid C# namespace identifier.
Replaces invalid characters with underscores and prefixes a leading
digit with an underscore.  Returns nil for segments that are empty or
conventionally excluded (bin, obj)."
  (let ((s (string-trim segment)))
    (cond
     ((string-empty-p s) nil)
     ((member (downcase s) '("bin" "obj")) nil)
     (t
      (let ((clean (replace-regexp-in-string "[^A-Za-z0-9_]" "_" s)))
        (if (string-match-p "\\`[0-9]" clean)
            (concat "_" clean)
          clean))))))

(defun sharpener-default-namespace (&optional target-dir)
  "Infer a C# namespace for a file created in TARGET-DIR.
TARGET-DIR defaults to `default-directory'.  The namespace is the
project's root namespace, followed by the sanitized directory segments
between the project root and TARGET-DIR.  Falls back to \"Project\" if
no project can be located."
  (let* ((dir (expand-file-name (or target-dir default-directory)))
         (proj-root (sharpener-project-root dir))
         (root-ns (or (sharpener--root-namespace dir) "Project")))
    (if (not proj-root)
        root-ns
      (let* ((rel (file-relative-name dir proj-root))
             (segments (unless (member rel '("." "./"))
                         (split-string rel "/" t)))
             (parts (delq nil (mapcar #'sharpener--sanitize-namespace-segment
                                      segments))))
        (string-join (cons root-ns parts) ".")))))

(defun sharpener--target-framework (&optional start)
  "Return the TargetFramework of the nearest project, or nil.
Handles the single <TargetFramework> case; for <TargetFrameworks>
\(multi-target) returns the first entry.  Search upward from START,
defaulting to `default-directory'."
  (when-let* ((proj (sharpener--project-file start)))
    (or (sharpener--read-msbuild-property proj "TargetFramework")
        (when-let* ((multi (sharpener--read-msbuild-property
                           proj "TargetFrameworks")))
          (car (split-string multi ";" t))))))

(defun sharpener--file-scoped-namespace-supported-p (&optional start)
  "Return non-nil if the nearest project can use file-scoped namespaces.
File-scoped namespaces require C# 10 / .NET 6 or later.  When the
framework can't be determined, assume yes (modern default).  Search
upward from START, defaulting to `default-directory'."
  (let ((tfm (sharpener--target-framework start)))
    (if (not tfm)
        t
      (if (string-match "net\\([0-9]+\\)\\.\\([0-9]+\\)" tfm)
          (>= (string-to-number (match-string 1 tfm)) 6)
        ;; net48 / netstandard etc. -> no
        (not (string-match-p "\\`net4\\|netstandard\\|netcoreapp[12]" tfm))))))

;;;; Command execution primitive

(defun sharpener--output-buffer ()
  "Return the dedicated dotnet output buffer, creating it if needed."
  (get-buffer-create sharpener-output-buffer-name))

(defun sharpener-run-command (cmd &optional dir callback)
  "Run CMD in DIR, sending output to `sharpener-output-buffer-name'.
DIR defaults to `default-directory'.  CALLBACK, if non-nil, is called
with no arguments when the process exits successfully (exit code 0).
The buffer uses `compilation-mode' so error navigation works."
  (let* ((default-directory (or dir default-directory))
         (buf (sharpener--output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n%s\n$ %s\n" (make-string 60 ?-) cmd)))
      (unless (derived-mode-p 'compilation-mode)
        (compilation-mode))
      (setq-local default-directory (or dir default-directory)))
    (let ((proc (start-process-shell-command "dotnet" buf cmd)))
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (memq (process-status p) '(exit signal))
           (let ((code (process-exit-status p))
                 (b (process-buffer p)))
             (when (buffer-live-p b)
               (with-current-buffer b
                 (let ((inhibit-read-only t))
                   (goto-char (point-max))
                   (insert (format "\n[%s: exit %d]\n"
                                   (process-name p) code)))))
             (when (and callback (zerop code))
               (funcall callback))))))
      (display-buffer buf)
      proc)))

(provide 'sharpener-util)
;;; sharpener-util.el ends here
