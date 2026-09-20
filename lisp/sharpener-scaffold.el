;;; sharpener-scaffold.el --- File generators for sharpener -*- lexical-binding: t; -*-

;;; Commentary:

;; File-level scaffolding for .NET projects.  Each generator resolves a
;; target path, creates the file, sets its major mode, and expands the
;; corresponding bundled yasnippet template into it.
;;
;; Generators are DATA-DRIVEN.  `sharpener-define-generator' both defines
;; the interactive command and records a spec in `sharpener--generators';
;; the `sharpener-new-file' transient is then built from that registry at
;; invoke time via `:setup-children'.  The upshot: defining a generator
;; is a single declarative form, and a user who defines their own
;; generator -- even after sharpener has loaded -- automatically gets it
;; as a command AND as an entry in the transient, with no further wiring.
;;
;;   (sharpener-define-generator controller
;;     :prompt "Controller name" :extension "cs" :snippet "controller"
;;     :key "C" :group "Web")
;;
;; See `sharpener-define-generator' for the full keyword list.  Two
;; scaffolding side effects -- saving the file and creating missing
;; directories -- are governed by `sharpener-save-after-scaffold' and
;; `sharpener-create-missing-dirs', each overridable per call.
;;
;; The razor-page generator is a deliberate exception: it creates a
;; view + code-behind PAIR and so is written by hand rather than via the
;; single-file macro.

;;; Code:

(require 'sharpener-util)
(require 'sharpener-snippets)
(require 'transient)
(require 'seq)
(require 'cl-lib)

(defcustom sharpener-csharp-mode
  (if (treesit-available-p) 'csharp-ts-mode 'csharp-mode)
  "Major mode to use for generated C# files.
Determines which snippet table is consulted, so it must match the
mode subdirectory under snippets/ that holds the C# templates."
  :type 'symbol
  :group 'sharpener)

;;;; The generator registry
;;
;; An alist mapping each generated command symbol to its spec plist
;; (:prompt :extension :snippet :mode :key :group).  Kept private -- the
;; structure is mutable and registration must go through the macro -- but
;; readable via `sharpener-generators' and browsable via
;; `sharpener-list-generators'.  Entries are appended in registration
;; order, so the transient displays them top-to-bottom in the order they
;; were defined (built-ins first, then any the user adds later).

(defvar sharpener--generators nil
  "Registry of scaffolding generators, as an alist (COMMAND . SPEC-PLIST).
Populated by `sharpener-define-generator'.  Do not modify directly; use
the macro to register and `sharpener-generators' to read.")

(defcustom sharpener-default-generator-group "Other"
  "Group label used for a generator defined without an explicit :group."
  :type 'string
  :group 'sharpener)

(defun sharpener-generators ()
  "Return a copy of the generator registry as an (COMMAND . SPEC) alist.
Safe for callers to inspect without risk of mutating the registry."
  (mapcar (lambda (entry) (cons (car entry) (copy-sequence (cdr entry))))
          sharpener--generators))

(defun sharpener--register-generator (command spec)
  "Register COMMAND with SPEC plist in `sharpener--generators'.
Last registration wins: re-registering an existing COMMAND replaces its
spec in place (preserving order).  If a DIFFERENT command already claims
the same :key within the same :group, emit a message noting the
override -- the newer binding still takes effect, matching the
expectation that a later definition overrides an earlier one."
  (let* ((key (plist-get spec :key))
         (group (or (plist-get spec :group)
                    sharpener-default-generator-group))
         (clash (seq-find
                 (lambda (entry)
                   (and (not (eq (car entry) command))
                        (equal key (plist-get (cdr entry) :key))
                        (equal group (or (plist-get (cdr entry) :group)
                                         sharpener-default-generator-group))))
                 sharpener--generators)))
    (when clash
      (message "sharpener: generator %s overrides key %S in group %S (was %s)"
               command key group (car clash)))
    ;; Replace in place if present, else append (preserve order).
    (if (assq command sharpener--generators)
        (setf (alist-get command sharpener--generators) spec)
      (setq sharpener--generators
            (append sharpener--generators (list (cons command spec)))))
    command))

;;;; The shared emit path

(defun sharpener--maybe-create-dir (dir create-dirs)
  "Ensure DIR exists, honoring the CREATE-DIRS policy.
CREATE-DIRS is a three-state value resolved against
`sharpener-create-missing-dirs'.  When creation is permitted, DIR is
made (with parents).  When it is not and DIR is missing: interactively,
prompt to create it (surfacing the option); non-interactively, signal
an error rather than silently proceeding."
  (unless (file-directory-p dir)
    (let ((allowed (sharpener-resolve-policy
                    create-dirs sharpener-create-missing-dirs)))
      (cond
       (allowed (make-directory dir t))
       ((and (eq create-dirs 'default) (called-interactively-p 'any)
             (y-or-n-p (format "Directory %s does not exist; create it? " dir)))
        (make-directory dir t))
       (t (user-error "Directory does not exist: %s (set `sharpener-create-missing-dirs' or pass create-dirs)"
                      dir))))))

(defun sharpener--prepare-file (path mode &optional create-dirs)
  "Create and visit PATH as an empty buffer in MODE, ready for expansion.
Signals a `user-error' if PATH already exists.  CREATE-DIRS is a
three-state value used literally: t forces directory creation, nil
forces \"do not create\" (a missing directory then errors, or prompts
interactively), and `default' consults `sharpener-create-missing-dirs'.
An omitted argument is nil -- i.e. \"force off\"; callers wanting the
custom default must pass `default' explicitly.  Public commands resolve
this at their boundary, so within sharpener the value is always explicit."
  (when (file-exists-p path)
    (user-error "File already exists: %s" path))
  (sharpener--maybe-create-dir (file-name-directory path) create-dirs)
  (find-file path)
  (funcall mode))

(defun sharpener--maybe-save (save)
  "Save the current buffer if the SAVE policy resolves true.
SAVE is three-state, resolved against `sharpener-save-after-scaffold'."
  (when (sharpener-resolve-policy save sharpener-save-after-scaffold)
    (save-buffer)))

(defun sharpener--new-from-snippet (name extension snippet mode
                                         &optional dir save create-dirs)
  "Create NAME.EXTENSION and expand SNIPPET (for MODE) into it.
NAME may contain a leading subdirectory (e.g. \"Models/Customer\"),
resolved against DIR (default `default-directory').  SAVE and
CREATE-DIRS are three-state values (t / nil / `default') used
literally -- see `sharpener-resolve-policy'.  They are NOT coerced here:
an explicit nil forces the behavior off, which is what lets a caller
\(including tests) suppress it even when the custom defaults it on.
Public commands resolve omission to `default' before calling in.
Returns the file path."
  (let* ((target-dir (expand-file-name (or dir default-directory)))
         (path (expand-file-name (concat name "." extension) target-dir)))
    (sharpener--prepare-file path mode create-dirs)
    (sharpener-expand-into-file snippet mode)
    (sharpener--maybe-save save)
    path))

;;;; The generator-defining macro

;;;###autoload
(defmacro sharpener-define-generator (name &rest spec)
  "Define an interactive single-file scaffolding generator.

NAME is an unquoted symbol naming the item type; the command defined is
`sharpener-new-NAME'.  SPEC is a keyword plist:

  :prompt     Minibuffer prompt string (default derived from NAME).
  :extension  File extension without the dot, e.g. \"cs\" (required).
  :snippet    Bundled yasnippet name to expand (default: NAME).
  :mode       Major mode for the new buffer / snippet table
              (default: `sharpener-csharp-mode').
  :key        Transient key string, e.g. \"c\" (default: NAME's initial).
  :group      Transient column label (default:
              `sharpener-default-generator-group').

The macro (1) defines `sharpener-new-NAME' as an autoloaded interactive
command taking (NAME-ARG &optional SAVE CREATE-DIRS), and (2) registers
the spec in `sharpener--generators' so the `sharpener-new-file'
transient offers it automatically.  Defining a generator is thus a
single declarative form, and user-defined generators join the transient
with no further wiring.

Last registration wins on key collisions (a message notes the
override)."
  (declare (indent 1) (doc-string 2))
  (let* ((sym (symbol-name name))
         (command (intern (format "sharpener-new-%s" sym)))
         (prompt (or (plist-get spec :prompt)
                     (format "%s name" (capitalize sym))))
         (extension (plist-get spec :extension))
         (snippet (or (plist-get spec :snippet) sym))
         (mode (or (plist-get spec :mode) 'sharpener-csharp-mode))
         (key (or (plist-get spec :key) (substring sym 0 1)))
         (group (plist-get spec :group)))
    (unless extension
      (error "sharpener-define-generator %s: :extension is required" name))
    `(progn
       ;;;###autoload
       (cl-defun ,command (name &optional (save 'default)
                                (create-dirs 'default))
         ,(format "Create a new %s file NAME and expand the %S template.

SAVE and CREATE-DIRS are three-state policy overrides: `default'
consults `sharpener-save-after-scaffold' / `sharpener-create-missing-dirs',
while t or nil force the behavior on or off.  Both default to `default'
when omitted (interactively or from Lisp), but an explicit nil is
honored as force-off -- so you can suppress a behavior the custom
enables.  This omitted-vs-explicit-nil distinction is why the command is
a `cl-defun'.  Defined by `sharpener-define-generator'." sym snippet)
         (interactive (list (read-string ,(format "%s: " prompt))
                            'default 'default))
         (sharpener--new-from-snippet
          name ,extension ,snippet ,mode nil save create-dirs))
       (sharpener--register-generator
        ',command
        (list :prompt ,prompt :extension ,extension :snippet ,snippet
              :mode ',mode :key ,key
              :group ,(or group 'sharpener-default-generator-group)))
       ',command)))

;;;; Built-in C# scalar generators (data-driven)

(sharpener-define-generator class
  :prompt "Class name" :extension "cs" :snippet "class"
  :key "c" :group "C# types")

(sharpener-define-generator interface
  :prompt "Interface name" :extension "cs" :snippet "interface"
  :key "i" :group "C# types")

(sharpener-define-generator record
  :prompt "Record name" :extension "cs" :snippet "record"
  :key "r" :group "C# types")

(sharpener-define-generator enum
  :prompt "Enum name" :extension "cs" :snippet "enum"
  :key "e" :group "C# types")

(sharpener-define-generator struct
  :prompt "Struct name" :extension "cs" :snippet "struct"
  :key "s" :group "C# types")

;;;; Razor page (view + code-behind pair) -- hand-written exception

;;;###autoload
(cl-defun sharpener-new-razor-page (name &optional (save 'default)
                                        (create-dirs 'default))
  "Create a Razor page NAME: NAME.cshtml.cs then NAME.cshtml.
The code-behind is created first so its @model target exists, then the
view.  Both files follow the same SAVE and CREATE-DIRS policies (three-
state: `default' consults the customs, t/nil force on/off; both default
to `default' when omitted, explicit nil is honored as force-off).  When
saving is enabled both land on disk, otherwise both are left as modified
buffers.  The view is left current for editing."
  (interactive (list (read-string "Page name: ") 'default 'default))
  (let* ((target-dir (expand-file-name default-directory))
         (cshtml (expand-file-name (concat name ".cshtml") target-dir)))
    (when (file-exists-p cshtml)
      (user-error "Page already exists: %s" cshtml))
    ;; Code-behind first so the view's @model resolves once both exist.
    (sharpener--new-from-snippet name "cshtml.cs" "razor-page-model"
                                 sharpener-csharp-mode target-dir
                                 save create-dirs)
    ;; Then the view, left current.
    (let ((view-path (expand-file-name (concat name ".cshtml") target-dir)))
      (sharpener--prepare-file view-path 'web-mode create-dirs)
      (sharpener-expand-into-file "razor-page" 'web-mode)
      (sharpener--maybe-save save)
      view-path)))

;; Register the razor generator too, so it appears in the transient.
;; It is not defined via the macro (it is a pair generator), so register
;; its spec by hand. :snippet is informational here.
(sharpener--register-generator
 'sharpener-new-razor-page
 (list :prompt "Page name" :extension "cshtml" :snippet "razor-page"
       :mode 'web-mode :key "p" :group "Web"))

;;;; The new-file transient (built from the registry)

(defun sharpener--generator-suffix (command spec)
  "Return a transient suffix list for COMMAND given its SPEC plist.
Form is (KEY DESCRIPTION COMMAND), as understood by
`transient-parse-suffixes'.  DESCRIPTION is derived from the command
name (the part after `sharpener-new-')."
  (let* ((key (plist-get spec :key))
         (name (replace-regexp-in-string
                "\\`sharpener-new-" "" (symbol-name command)))
         (desc (capitalize (replace-regexp-in-string "-" " " name))))
    (list key desc command)))

(defun sharpener--build-transient-children (_)
  "Build `sharpener-new-file' children from the generator registry.
Groups generators by :group (in first-seen order) and returns one
transient column vector per group, each headed by the group label.
Intended as a `:setup-children' function."
  (let ((groups nil))          ; alist: group-label -> list of suffixes
    (dolist (entry (sharpener-generators))
      (let* ((command (car entry))
             (spec (cdr entry))
             (group (or (plist-get spec :group)
                        sharpener-default-generator-group))
             (suffix (sharpener--generator-suffix command spec)))
        (if (assoc group groups)
            (setf (alist-get group groups nil nil #'equal)
                  (append (alist-get group groups nil nil #'equal)
                          (list suffix)))
          (setq groups (append groups (list (cons group (list suffix))))))))
    (transient-parse-suffixes
     'sharpener-new-file
     (mapcar (lambda (group-entry)
               (apply #'vector (car group-entry) (cdr group-entry)))
             groups))))

;;;###autoload (autoload 'sharpener-new-file "sharpener-scaffold" nil t)
(transient-define-prefix sharpener-new-file ()
  "Scaffold a new .NET source file in the current directory.
Mirrors Visual Studio's \"Add New Item\" picker.  The item list is built
from the generator registry (`sharpener--generators') at invoke time, so
generators defined via `sharpener-define-generator' -- including your
own -- appear here automatically."
  ["Add New Item"
   :class transient-columns
   :setup-children sharpener--build-transient-children])

;;;; Registry inspection

;;;###autoload
(defun sharpener-list-generators ()
  "Display the registered scaffolding generators in a help buffer.
Shows each command with its key, group, snippet, and file extension --
useful for confirming a user-defined generator registered correctly and
for seeing what the `sharpener-new-file' transient will offer."
  (interactive)
  (help-setup-xref (list #'sharpener-list-generators)
                   (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (princ "sharpener scaffolding generators\n")
    (princ "================================\n\n")
    (dolist (entry (sharpener-generators))
      (let ((command (car entry))
            (spec (cdr entry)))
        (princ (format "%-28s  key %-3s  group %-10s  .%s\n"
                       command
                       (or (plist-get spec :key) "?")
                       (or (plist-get spec :group)
                           sharpener-default-generator-group)
                       (plist-get spec :extension)))))))

(provide 'sharpener-scaffold)
;;; sharpener-scaffold.el ends here
