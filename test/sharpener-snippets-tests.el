(provide 'sharpener-snippets-tests)
;;; sharpener-snippets-tests.el ends here

;;; sharpener-snippets-tests.el --- Tests for sharpener-snippets -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the yasnippet bridge: snippet registration, the
;; snippet-body API (`sharpener-yas--*'), and expansion into files.
;;
;; The body-API tests are pure (they read buffer context and format
;; strings), so they need no dotnet.  The registration test needs
;; yasnippet; it skips if yasnippet isn't available rather than failing,
;; so the suite still runs on a bare Emacs -- though in the clean
;; container that skip is itself informative (it means yasnippet wasn't
;; installed, which the package's Package-Requires says it needs).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sharpener-snippets)
(require 'sharpener-test-common)

(defun sharpener-snippets-test--yas-available-p ()
  "Return non-nil if yasnippet is loadable."
  (require 'yasnippet nil t))

;;;; Snippet-body API -- pure, no dotnet, no yasnippet

(ert-deftest sharpener-snippets-test-titleize-splits-pascalcase ()
  "PascalCase is split into space-separated words."
  (should (equal "Customer Order"
                 (sharpener-yas--titleize "CustomerOrder")))
  (should (equal "Order" (sharpener-yas--titleize "Order")))
  ;; Empty input falls back to a sensible default rather than "".
  (should (equal "Page" (sharpener-yas--titleize ""))))

(ert-deftest sharpener-snippets-test-type-name-from-buffer ()
  "Type name derives from the buffer's file base name."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/proj/Customer.cs")
    (should (equal "Customer" (sharpener-yas--type-name))))
  ;; No file name -> a placeholder, never nil.
  (with-temp-buffer
    (setq buffer-file-name nil)
    (should (stringp (sharpener-yas--type-name)))))

(ert-deftest sharpener-snippets-test-type-name-interface-prefix ()
  "With an I prefix requested, a non-I name gains it; an I-name keeps it."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/proj/Repository.cs")
    (should (equal "IRepository" (sharpener-yas--type-name "I"))))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/proj/IWidget.cs")
    ;; Already prefixed -- must not double to IIWidget.
    (should (equal "IWidget" (sharpener-yas--type-name "I")))))

;;;; Registration -- needs yasnippet

(ert-deftest sharpener-snippets-test-register-adds-to-yas-dirs ()
  "Registering adds the bundled snippets dir to `yas-snippet-dirs'."
  (skip-unless (sharpener-snippets-test--yas-available-p))
  ;; Guard: the package must know where its snippets live.
  (should sharpener--snippets-dir)
  (should (file-directory-p sharpener--snippets-dir))
  (let ((yas-snippet-dirs (if (listp yas-snippet-dirs)
                              (copy-sequence yas-snippet-dirs)
                            (list yas-snippet-dirs))))
    (sharpener-register-snippets)
    ;; `with-eval-after-load' fires synchronously when yasnippet is
    ;; already loaded, so the dir should be present now.
    (should (member sharpener--snippets-dir yas-snippet-dirs))))

(ert-deftest sharpener-snippets-test-snippets-dir-resolves-to-real-tree ()
  "The computed snippets dir actually contains the expected mode subdirs."
  (should sharpener--snippets-dir)
  ;; The csharp snippets live under a mode-named subdir; at least one of
  ;; the C# mode dirs should exist in the shipped tree.
  (should (or (file-directory-p
               (expand-file-name "csharp-ts-mode" sharpener--snippets-dir))
              (file-directory-p
               (expand-file-name "csharp-mode" sharpener--snippets-dir)))))

(provide 'sharpener-snippets-tests)
;;; sharpener-snippets-tests.el ends here
