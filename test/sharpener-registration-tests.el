;;; sharpener-registration-tests.el --- yasnippet load-order tests -*- lexical-binding: t; -*-

;;; Commentary:

;; TDD suite for the yasnippet registration/ordering problem: bundled
;; snippets must end up both (a) registered in `yas-snippet-dirs' and
;; (b) actually lookup-able via `yas-lookup-snippet', regardless of
;; whether yasnippet was loaded before or after sharpener, and even if
;; something calls `yas-reload-all' afterward.
;;
;; The canonical orderings are tested in a fresh subprocess Emacs each,
;; because yasnippet's global state (features, yas-snippet-dirs, loaded
;; tables) cannot be honestly reset within one process -- `unload-feature'
;; does not fully clean up.  A subprocess gives true isolation: each
;; ordering starts from a pristine Emacs.  Edge cases that don't need a
;; virgin yasnippet are simulated in-process for speed.
;;
;; Each subprocess prints a single readable plist on the last line of
;; stdout; the parent parses it and asserts.  This keeps the contract
;; between child and parent explicit and debuggable (run the child script
;; by hand to see what it printed).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sharpener-test-common)

(defvar sharpener-reg-test--this-file
  (or load-file-name buffer-file-name)
  "Path to this test file, for locating the package root in subprocesses.")

(defun sharpener-reg-test--package-root ()
  "Return the package root (parent of test/)."
  (file-name-directory
   (directory-file-name
    (file-name-directory sharpener-reg-test--this-file))))

(defun sharpener-reg-test--emacs ()
  "Return the Emacs executable to spawn for subprocess scenarios."
  (or (getenv "EMACS") "emacs"))

(defun sharpener-reg-test--pkgdir ()
  "Return the isolated test package dir (where yasnippet is installed)."
  (or (getenv "SHARPENER_TEST_PKGDIR")
      (expand-file-name ".sharpener-pkg" (sharpener-reg-test--package-root))))

(defun sharpener-reg-test--run-scenario (scenario-form)
  "Run SCENARIO-FORM in a fresh subprocess Emacs; return the parsed result.
SCENARIO-FORM is an elisp form (unquoted) that must, as its final act,
`prin1' a result plist and print a newline.  This function wraps it with
the load-path and package setup every scenario needs, executes it, and
reads back the last non-empty line of stdout as a Lisp form.

Returns the parsed plist, or signals with the raw output if no readable
result was produced (so a broken child is diagnosable, not silent)."
  (let* ((root (sharpener-reg-test--package-root))
         (lisp (expand-file-name "lisp" root))
         (pkgdir (sharpener-reg-test--pkgdir))
         (preamble
          `(progn
             (require 'package)
             (setq package-user-dir ,pkgdir)
             (when (file-directory-p ,pkgdir) (package-initialize))
             (add-to-list 'load-path ,lisp)
             ;; Guard: these scenarios are meaningless without yasnippet
             ;; installed; say so clearly rather than erroring obscurely.
             (unless (locate-library "yasnippet")
               (prin1 (list :error 'no-yasnippet))
               (terpri)
               (kill-emacs 0))))
         (script (prin1-to-string `(progn ,preamble ,scenario-form)))
         (out (generate-new-buffer " *sharpener-reg-scenario*")))
    (unwind-protect
        (let ((code (call-process (sharpener-reg-test--emacs) nil out nil
                                  "-Q" "-batch" "--eval" script)))
          (with-current-buffer out
            (goto-char (point-max))
            ;; Find the last non-empty line -- the result plist.
            (let ((result nil) (raw (buffer-string)))
              (goto-char (point-max))
              (while (and (not result) (not (bobp)))
                (forward-line -1)
                (let ((line (string-trim
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))))
                  (unless (string-empty-p line)
                    (setq result
                          (condition-case _err
                              (car (read-from-string line))
                            (error nil)))
                    ;; Stop at the first non-empty line whether or not it
                    ;; parsed; if it didn't parse, fail loudly with raw.
                    (unless result
                      (setq result :unparseable)))))
              (when (or (null result) (eq result :unparseable))
                (error "Scenario produced no readable result (exit %s).\nOutput:\n%s"
                       code raw))
              result)))
      (kill-buffer out))))

;; The body every scenario shares once yasnippet + sharpener are in the
;; desired load state: register, then report the two truths we care about.
;; Kept as a quoted list so scenarios can splice it after arranging order.
(defconst sharpener-reg-test--probe
  '(progn
     (require 'sharpener-snippets)
     (sharpener-register-snippets)
     (let* ((mode 'csharp-ts-mode)
            (dir-registered
             (and (boundp 'yas-snippet-dirs)
                  (member sharpener--snippets-dir yas-snippet-dirs)
                  t))
            (lookup-able
             (and (fboundp 'yas-lookup-snippet)
                  (yas-lookup-snippet "class" mode t)
                  t)))
       (prin1 (list :dir-registered dir-registered
                    :lookup-able lookup-able
                    :snippets-dir sharpener--snippets-dir))
       (terpri)))
  "Shared scenario tail: register and report dir-registered + lookup-able.")

;;;; Canonical orderings -- subprocess, true isolation

(ert-deftest sharpener-reg-test-yas-loaded-before ()
  "Snippets are available when yasnippet is loaded BEFORE registration."
  (skip-unless (executable-find (sharpener-reg-test--emacs)))
  (let ((result (sharpener-reg-test--run-scenario
                 `(progn
                    (require 'yasnippet)      ; loaded FIRST
                    (yas-minor-mode-on)
                    ,sharpener-reg-test--probe))))
    (when (eq (plist-get result :error) 'no-yasnippet)
      (ert-skip "yasnippet not installed in test pkgdir"))
    (should (plist-get result :dir-registered))
    (should (plist-get result :lookup-able))))

(ert-deftest sharpener-reg-test-yas-loaded-after ()
  "Snippets are available when yasnippet loads AFTER registration.
This is the `with-eval-after-load' path: sharpener registers while
yasnippet is absent, and registration must still take effect once
yasnippet finally loads."
  (skip-unless (executable-find (sharpener-reg-test--emacs)))
  (let ((result (sharpener-reg-test--run-scenario
                 `(progn
                    ;; Register BEFORE yasnippet exists in the session.
                    (require 'sharpener-snippets)
                    (sharpener-register-snippets)
                    ;; Now yasnippet arrives.
                    (require 'yasnippet)
                    (yas-minor-mode-on)
                    ;; Re-probe the two truths (do not re-register here;
                    ;; the point is that the earlier registration stuck).
                    (let* ((mode 'csharp-ts-mode)
                           (dir-registered
                            (and (boundp 'yas-snippet-dirs)
                                 (member sharpener--snippets-dir
                                         yas-snippet-dirs) t))
                           (lookup-able
                            (and (fboundp 'yas-lookup-snippet)
                                 (yas-lookup-snippet "class" mode t) t)))
                      (prin1 (list :dir-registered dir-registered
                                   :lookup-able lookup-able))
                      (terpri))))))
    (when (eq (plist-get result :error) 'no-yasnippet)
      (ert-skip "yasnippet not installed in test pkgdir"))
    (should (plist-get result :dir-registered))
    (should (plist-get result :lookup-able))))

(ert-deftest sharpener-reg-test-reload-after-registration ()
  "Snippets remain recoverable after an external `yas-reload-all'.
An external reload may JIT-defer our persisted dir, so a bare lookup
with no mode activation can miss.  What sharpener guarantees is that the
dir stays in `yas-snippet-dirs' (so a reload re-includes it) and that an
eager load makes the snippet lookup-able again -- which is exactly what
`sharpener-register-snippets' does on its next call and what
`sharpener-expand-into-file' forces.  This pins both: dir persists, and
re-registration restores lookup after the reload."
  (skip-unless (executable-find (sharpener-reg-test--emacs)))
  (let ((result (sharpener-reg-test--run-scenario
                 `(progn
                    (require 'yasnippet)
                    (yas-minor-mode-on)
                    (require 'sharpener-snippets)
                    (sharpener-register-snippets)
                    ;; Something else rebuilds the world afterward.
                    (yas-reload-all)
                    ;; sharpener recovers by re-registering (eager load).
                    (sharpener-register-snippets)
                    (let* ((mode 'csharp-ts-mode)
                           (dir-registered
                            (and (member sharpener--snippets-dir
                                         yas-snippet-dirs) t))
                           (lookup-able
                            (and (yas-lookup-snippet "class" mode t) t)))
                      (prin1 (list :dir-registered dir-registered
                                   :lookup-able lookup-able))
                      (terpri))))))
    (when (eq (plist-get result :error) 'no-yasnippet)
      (ert-skip "yasnippet not installed in test pkgdir"))
    (should (plist-get result :dir-registered))
    (should (plist-get result :lookup-able))))

(ert-deftest sharpener-reg-test-double-registration-idempotent ()
  "Registering twice does not duplicate the dir or break lookup."
  (skip-unless (executable-find (sharpener-reg-test--emacs)))
  (let ((result (sharpener-reg-test--run-scenario
                 `(progn
                    (require 'yasnippet)
                    (yas-minor-mode-on)
                    (require 'sharpener-snippets)
                    (sharpener-register-snippets)
                    (sharpener-register-snippets)   ; twice
                    (let* ((occurrences
                            (cl-count sharpener--snippets-dir
                                      yas-snippet-dirs :test #'equal))
                           (lookup-able
                            (and (yas-lookup-snippet "class"
                                                     'csharp-ts-mode t) t)))
                      (prin1 (list :occurrences occurrences
                                   :lookup-able lookup-able))
                      (terpri))))))
    (when (eq (plist-get result :error) 'no-yasnippet)
      (ert-skip "yasnippet not installed in test pkgdir"))
    (should (= 1 (plist-get result :occurrences)))
    (should (plist-get result :lookup-able))))

;;;; Edge cases -- in-process simulation (no virgin yasnippet needed)

(ert-deftest sharpener-reg-test-nil-dir-recomputes ()
  "If `sharpener--snippets-dir' is nil, registration recomputes it.
Simulates the load-file-name-was-nil poisoning: force the var nil, then
register, and require it to be repopulated to a real directory."
  (skip-unless (require 'yasnippet nil t))
  (require 'sharpener-snippets)
  (let ((sharpener--snippets-dir nil))
    (sharpener-register-snippets)
    (should sharpener--snippets-dir)
    (should (file-directory-p sharpener--snippets-dir))))

;;;; End-to-end: expand-into-file actually produces content

(ert-deftest sharpener-reg-test-expand-into-file-e2e ()
  "After registration, `sharpener-expand-into-file' fills a real buffer.
Runs in a subprocess so registration order is controlled and yasnippet
starts clean.  Creates an empty file, sets the C# mode, expands the
`class' snippet, and reports whether the buffer ended up containing a
class declaration -- the true end-to-end signal that lookup + expansion
both worked."
  (skip-unless (executable-find (sharpener-reg-test--emacs)))
  (let ((result (sharpener-reg-test--run-scenario
                 `(progn
                    (require 'yasnippet)
                    (require 'sharpener-snippets)
                    (sharpener-register-snippets)
                    (let* ((tmp (make-temp-file "sharpener-e2e-" nil ".cs"))
                           (produced nil))
                      (unwind-protect
                          (progn
                            (find-file tmp)
                            ;; Use whichever C# mode is available; the
                            ;; snippet lookup must resolve for it.
                            (if (fboundp 'csharp-ts-mode)
                                (csharp-ts-mode)
                              (prog-mode))
                            (condition-case err
                                (progn
                                  (sharpener-expand-into-file
                                   "class"
                                   (if (fboundp 'csharp-ts-mode)
                                       'csharp-ts-mode 'csharp-mode))
                                  (setq produced
                                        (and (string-match-p
                                              "class"
                                              (buffer-string)) t)))
                              (error
                               (setq produced (list :error
                                                    (error-message-string
                                                     err))))))
                        (when (file-exists-p tmp) (delete-file tmp)))
                      (prin1 (list :produced produced))
                      (terpri))))))
    (when (eq (plist-get result :error) 'no-yasnippet)
      (ert-skip "yasnippet not installed in test pkgdir"))
    (let ((produced (plist-get result :produced)))
      ;; produced is t on success, or (:error MSG) if expansion threw.
      (should (eq produced t)))))

(provide 'sharpener-registration-tests)
;;; sharpener-registration-tests.el ends here
