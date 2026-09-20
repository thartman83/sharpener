;;; sharpener-util-tests.el --- Tests for sharpener-util -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the discovery, inference, and MSBuild-reading functions
;; in sharpener-util.  Fast tests are pure path logic; :dotnet-tagged
;; tests generate real fixtures via the shared harness and skip cleanly
;; when the CLI is absent.
;;
;; Run all:
;;   emacs -batch -L lisp -L test -l ert -l test/sharpener-util-tests.el \
;;         -f ert-run-tests-batch-and-exit
;; Fast only:
;;   ... --eval '(ert-run-tests-batch-and-exit (quote (not (tag :dotnet))))'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sharpener-util)
(require 'sharpener-test-common)

;;;; --- Fast tests: no dotnet, pure path logic -------------------------

(ert-deftest sharpener-test-namespace-sanitize-drops-bin-obj ()
  "bin and obj segments are excluded from inferred namespaces."
  (should (null (sharpener--sanitize-namespace-segment "bin")))
  (should (null (sharpener--sanitize-namespace-segment "obj")))
  (should (null (sharpener--sanitize-namespace-segment "BIN")))
  (should (equal "Services" (sharpener--sanitize-namespace-segment "Services"))))

(ert-deftest sharpener-test-namespace-sanitize-invalid-chars ()
  "Invalid identifier characters become underscores."
  (should (equal "My_Project"
                 (sharpener--sanitize-namespace-segment "My-Project")))
  (should (equal "a_b_c"
                 (sharpener--sanitize-namespace-segment "a.b.c"))))

(ert-deftest sharpener-test-namespace-sanitize-leading-digit ()
  "A segment starting with a digit is prefixed with an underscore."
  (should (equal "_2Fast"
                 (sharpener--sanitize-namespace-segment "2Fast"))))

(ert-deftest sharpener-test-namespace-sanitize-empty ()
  "Empty or whitespace-only segments yield nil."
  (should (null (sharpener--sanitize-namespace-segment "")))
  (should (null (sharpener--sanitize-namespace-segment "   "))))

(ert-deftest sharpener-test-file-scoped-namespace-by-framework ()
  "File-scoped namespace support is gated on the framework moniker."
  (cl-letf (((symbol-function 'sharpener--target-framework)
             (lambda (&optional _start) "net8.0")))
    (should (sharpener--file-scoped-namespace-supported-p)))
  (cl-letf (((symbol-function 'sharpener--target-framework)
             (lambda (&optional _start) "net48")))
    (should-not (sharpener--file-scoped-namespace-supported-p)))
  (cl-letf (((symbol-function 'sharpener--target-framework)
             (lambda (&optional _start) "netstandard2.0")))
    (should-not (sharpener--file-scoped-namespace-supported-p)))
  ;; Unknown framework -> assume modern.
  (cl-letf (((symbol-function 'sharpener--target-framework)
             (lambda (&optional _start) nil)))
    (should (sharpener--file-scoped-namespace-supported-p))))

;;;; --- Integration tests: real dotnet fixtures ------------------------

(ert-deftest sharpener-test-solution-root-flat ()
  "Solution root is found when the .sln/.slnx sits beside the caller."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (let ((sln (sharpener-test--make-solution root "Flat")))
      (should (file-exists-p sln))
      ;; From the sandbox root itself.
      (should (equal (file-truename (file-name-as-directory root))
                     (file-truename
                      (sharpener-test--in-dir root
                                              #'sharpener-solution-root)))))))

(ert-deftest sharpener-test-solution-root-from-nested-project ()
  "Solution root is discovered by walking up from a nested project dir."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (sharpener-test--make-solution root "Nested")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj)))
      ;; From deep inside the project, root discovery should climb to the
      ;; solution directory, not stop at the project.
      (should (equal (file-truename (file-name-as-directory root))
                     (file-truename
                      (sharpener-test--in-dir proj-dir
                                              #'sharpener-solution-root)))))))

(ert-deftest sharpener-test-solution-root-handles-slnx-or-sln ()
  "Whatever solution extension the SDK emits, discovery finds it.
This is the version-transition guard: .NET 10 defaults to .slnx, .NET 9
and earlier to .sln.  The test asserts the behavior holds for whichever
one this SDK produced, and records which it was."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (let* ((sln (sharpener-test--make-solution root "Fmt"))
           (ext (file-name-extension sln)))
      (should (member ext '("sln" "slnx")))
      (ert-info ((format "SDK produced a .%s solution" ext))
        (should (equal (file-truename (file-name-as-directory root))
                       (file-truename
                        (sharpener-test--in-dir root
                                                #'sharpener-solution-root))))))))

(ert-deftest sharpener-test-project-root-vs-solution-root ()
  "project-root stops at the project; solution-root climbs past it."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (sharpener-test--make-solution root "Split")
    (let* ((proj (sharpener-test--make-project root "libs/Widgets"))
           (proj-dir (file-name-directory proj)))
      (sharpener-test--in-dir proj-dir
        (lambda ()
          (should (equal (file-truename proj-dir)
                         (file-truename (sharpener-project-root))))
          (should (equal (file-truename (file-name-as-directory root))
                         (file-truename (sharpener-solution-root)))))))))

(ert-deftest sharpener-test-solution-root-fallback-no-sln ()
  "With a project but no solution, solution-root falls back to the project."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    ;; No solution created -- just a bare project.
    (let* ((proj (sharpener-test--make-project root "Standalone"))
           (proj-dir (file-name-directory proj)))
      (should (equal (file-truename proj-dir)
                     (file-truename
                      (sharpener-test--in-dir proj-dir
                                              #'sharpener-solution-root)))))))

(ert-deftest sharpener-test-namespace-inference-nested ()
  "Inferred namespace joins root namespace with sanitized subdirs."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (sharpener-test--make-solution root "NsTest")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj))
           ;; A source subdir two levels into the project.
           (deep (expand-file-name "Services/Auth" proj-dir)))
      (make-directory deep t)
      ;; Project file is Core.csproj -> root namespace "Core".
      (should (equal "Core.Services.Auth"
                     (sharpener-default-namespace deep)))
      ;; At the project root, just the root namespace.
      (should (equal "Core"
                     (sharpener-default-namespace proj-dir))))))

(ert-deftest sharpener-test-namespace-explicit-rootnamespace ()
  "An explicit <RootNamespace> in the csproj overrides the filename."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (sharpener-test--make-solution root "RnsTest")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj)))
      ;; Inject a RootNamespace property into the generated csproj.
      (with-temp-buffer
        (insert-file-contents proj)
        (goto-char (point-min))
        (re-search-forward "<PropertyGroup>")
        (insert "\n    <RootNamespace>Contoso.Platform</RootNamespace>")
        (write-region (point-min) (point-max) proj))
      (should (equal "Contoso.Platform"
                     (sharpener-default-namespace proj-dir)))
      (should (equal "Contoso.Platform.Models"
                     (sharpener-default-namespace
                      (expand-file-name "Models" proj-dir)))))))

(ert-deftest sharpener-test-target-framework-read ()
  "The target framework is read back from a generated project."
  :tags '(:dotnet)
  (skip-unless (sharpener-test--dotnet-available-p))
  (sharpener-test--with-sandbox root
    (let* ((proj (sharpener-test--make-project root "Fw"))
           (proj-dir (file-name-directory proj)))
      (sharpener-test--in-dir proj-dir
        (lambda ()
          (let ((tfm (sharpener--target-framework)))
            ;; Whatever the SDK's default, it should look like netN.N.
            (should (stringp tfm))
            (should (string-match-p "\\`net[0-9]" tfm))))))))

(provide 'sharpener-util-tests)
;;; sharpener-util-tests.el ends here
