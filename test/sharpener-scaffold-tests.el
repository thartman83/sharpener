;;; sharpener-scaffold-tests.el --- Tests for sharpener-scaffold -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the file generators.  These assert the file-system
;; contract: a generator creates a file at the expected path with the
;; expected name and extension, creates intermediate directories, and
;; refuses to clobber an existing file.
;;
;; Generators expand a yasnippet template into the new file, so a full
;; end-to-end generation needs both a real project (for namespace
;; inference) and yasnippet (for expansion).  Those tests are tagged
;; :dotnet and additionally skip without yasnippet.  The path-contract
;; pieces that don't depend on expansion are tested against the lower
;; level `sharpener--prepare-file' where possible to keep some coverage
;; even on a bare Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sharpener-scaffold)
(require 'sharpener-test-common)

(defun sharpener-scaffold-test--yas-available-p ()
  "Return non-nil if yasnippet is loadable."
  (require 'yasnippet nil t))

;;;; prepare-file: path resolution and the clobber guard (no expansion)

(ert-deftest sharpener-scaffold-test-prepare-creates-and-visits ()
  "`sharpener--prepare-file' creates the file, its dirs, and visits it."
  (sharpener-test--with-sandbox root
    (let* ((path (expand-file-name "Sub/Dir/Thing.cs" root))
           (buf nil))
      (unwind-protect
          (progn
            (setq buf (find-buffer-visiting
                       (progn (sharpener--prepare-file path 'prog-mode t)
                              path)))
            (should (file-exists-p (file-name-directory path)))
            ;; The visiting buffer is current and in the requested mode.
            (should (eq major-mode 'prog-mode))
            (should (equal (expand-file-name path)
                           (expand-file-name (buffer-file-name)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest sharpener-scaffold-test-prepare-refuses-existing ()
  "`sharpener--prepare-file' errors rather than clobbering."
  (sharpener-test--with-sandbox root
    (let ((path (expand-file-name "Existing.cs" root)))
      (write-region "// already here\n" nil path)
      (should-error (sharpener--prepare-file path 'prog-mode)
                    :type 'user-error))))

;;;; Full generation: needs a real project + yasnippet

(ert-deftest sharpener-scaffold-test-new-class-creates-file ()
  "`sharpener-new-class' creates NAME.cs in the target project dir."
  :tags '(:dotnet)
  (skip-unless (and (sharpener-test--dotnet-available-p)
                    (sharpener-scaffold-test--yas-available-p)))
  (sharpener-test--with-sandbox root
    (sharpener-register-snippets)
    (sharpener-test--make-solution root "ScaffoldTest")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj))
           (default-directory proj-dir)
           (created nil))
      (unwind-protect
          (progn
            (setq created (sharpener-new-class "Customer" t))
            (should (equal (expand-file-name "Customer.cs" proj-dir)
                           (expand-file-name created)))
            (should (file-exists-p created))
            ;; The expanded body should mention the class name and the
            ;; inferred namespace root (project is Core).
            (with-current-buffer (find-buffer-visiting created)
              (let ((text (buffer-string)))
                (should (string-match-p "class Customer" text))
                (should (string-match-p "namespace Core" text)))))
        (when-let* ((b (and created (find-buffer-visiting created))))
          (kill-buffer b))))))

(ert-deftest sharpener-scaffold-test-new-class-subdir-namespace ()
  "A class made in a subdir gets the subdir appended to its namespace."
  :tags '(:dotnet)
  (skip-unless (and (sharpener-test--dotnet-available-p)
                    (sharpener-scaffold-test--yas-available-p)))
  (sharpener-test--with-sandbox root
    (sharpener-register-snippets)
    (sharpener-test--make-solution root "ScaffoldNs")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj))
           (default-directory proj-dir)
           (created nil))
      (unwind-protect
          (progn
            ;; NAME carries a subdir: Services/Auth/TokenService.
            (setq created (sharpener-new-class "Services/TokenService" t))
            (should (file-exists-p created))
            (with-current-buffer (find-buffer-visiting created)
              (should (string-match-p "namespace Core.Services"
                                      (buffer-string)))))
        (when-let* ((b (and created (find-buffer-visiting created))))
          (kill-buffer b))))))

(ert-deftest sharpener-scaffold-test-razor-page-creates-pair ()
  "`sharpener-new-razor-page' creates both .cshtml and .cshtml.cs."
  :tags '(:dotnet)
  (skip-unless (and (sharpener-test--dotnet-available-p)
                    (sharpener-scaffold-test--yas-available-p)))
  (sharpener-test--with-sandbox root
    (sharpener-register-snippets)
    (sharpener-test--make-solution root "RazorTest")
    (let* ((proj (sharpener-test--make-project root "Web" "web"))
           (proj-dir (file-name-directory proj))
           (pages-dir (expand-file-name "Pages" proj-dir))
           (default-directory pages-dir)
           (view nil))
      (make-directory pages-dir t)
      (unwind-protect
          (progn
            (setq view (sharpener-new-razor-page "Index" t))
            (should (file-exists-p view))
            (should (file-exists-p (concat view ".cs")))
            (should (equal "cshtml" (file-name-extension view))))
        (dolist (p (list view (and view (concat view ".cs"))))
          (when-let* ((b (and p (find-buffer-visiting p))))
            (kill-buffer b)))))))

;;;; Registry invariants -- pure, no dotnet/yasnippet needed

(ert-deftest sharpener-scaffold-test-registry-commands-callable ()
  "Every registered generator names a real interactive command.
This invariant would have caught a macro that registered a spec without
defining its command (or vice versa)."
  (should sharpener--generators)
  (dolist (entry (sharpener-generators))
    (let ((command (car entry)))
      (should (fboundp command))
      (should (commandp command)))))

(ert-deftest sharpener-scaffold-test-registry-has-builtins ()
  "The five C# scalar generators and the razor page are registered."
  (let ((commands (mapcar #'car (sharpener-generators))))
    (dolist (c '(sharpener-new-class sharpener-new-interface
                 sharpener-new-record sharpener-new-enum
                 sharpener-new-struct sharpener-new-razor-page))
      (should (memq c commands)))))

(ert-deftest sharpener-scaffold-test-define-generator-registers ()
  "`sharpener-define-generator' defines the command and registers a spec.
Also exercises last-in-wins: redefining replaces the spec in place."
  (unwind-protect
      (progn
        (sharpener-define-generator sharpener-test-widget
          :prompt "Widget name" :extension "cs" :snippet "class"
          :key "W" :group "Test")
        (should (fboundp 'sharpener-new-sharpener-test-widget))
        (should (commandp 'sharpener-new-sharpener-test-widget))
        (let ((spec (alist-get 'sharpener-new-sharpener-test-widget
                               (sharpener-generators))))
          (should (equal "cs" (plist-get spec :extension)))
          (should (equal "Test" (plist-get spec :group)))))
    ;; Clean up the test generator so it doesn't leak into other tests.
    (setq sharpener--generators
          (assq-delete-all 'sharpener-new-sharpener-test-widget
                           sharpener--generators))
    (fmakunbound 'sharpener-new-sharpener-test-widget)))

;;;; create-dirs guard -- no dotnet needed

(ert-deftest sharpener-scaffold-test-create-dirs-nil-errors ()
  "With create-dirs forced nil and a missing dir, prepare-file errors.
Non-interactive path: a missing directory is a hard error rather than a
silent mkdir, protecting against typo'd subdirectories."
  (sharpener-test--with-sandbox root
    (let ((path (expand-file-name "Nope/Missing/Thing.cs" root)))
      ;; Force create-dirs nil; dir does not exist; not interactive.
      (should-error (sharpener--prepare-file path 'prog-mode nil)
                    :type 'user-error))))

(ert-deftest sharpener-scaffold-test-create-dirs-t-makes-dir ()
  "With create-dirs forced t, the missing directory is created."
  (sharpener-test--with-sandbox root
    (let* ((path (expand-file-name "Made/Here/Thing.cs" root))
           (buf nil))
      (unwind-protect
          (progn
            (sharpener--prepare-file path 'prog-mode t)
            (setq buf (find-buffer-visiting path))
            (should (file-directory-p (file-name-directory path))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; Save policy -- end-to-end, asserts on-disk content by reading back

(ert-deftest sharpener-scaffold-test-save-writes-to-disk ()
  "With save forced t, the generated file exists on disk with content.
Reads the file back into a fresh buffer to prove the bytes are on disk,
not merely in the visiting buffer -- the exact gap that a buffer-only
check would miss."
  :tags '(:dotnet)
  (skip-unless (and (sharpener-test--dotnet-available-p)
                    (sharpener-scaffold-test--yas-available-p)))
  (sharpener-test--with-sandbox root
    (sharpener-register-snippets)
    (sharpener-test--make-solution root "SaveTest")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj))
           (default-directory proj-dir)
           (created nil))
      (unwind-protect
          (progn
            ;; Force save on via the per-call override.
            (setq created (sharpener-new-class "Saved" t))
            (should (file-exists-p created))
            ;; Prove content is on DISK, not just in the buffer.
            (with-temp-buffer
              (insert-file-contents created)
              (should (string-match-p "class Saved" (buffer-string)))))
        (when-let* ((b (and created (find-buffer-visiting created))))
          (kill-buffer b))))))

(ert-deftest sharpener-scaffold-test-no-save-leaves-buffer-modified ()
  "With save forced nil, the buffer is modified and unsaved.
Complements the save test: confirms the default (nil) behavior really
does leave the file unwritten, so the two policies are distinct."
  :tags '(:dotnet)
  (skip-unless (and (sharpener-test--dotnet-available-p)
                    (sharpener-scaffold-test--yas-available-p)))
  (sharpener-test--with-sandbox root
    (sharpener-register-snippets)
    (sharpener-test--make-solution root "NoSaveTest")
    (let* ((proj (sharpener-test--make-project root "src/Core"))
           (proj-dir (file-name-directory proj))
           (default-directory proj-dir)
           (created nil) (buf nil))
      (unwind-protect
          (progn
            (setq created (sharpener-new-class "Unsaved" nil))
            (setq buf (find-buffer-visiting created))
            (should (buffer-live-p buf))
            (with-current-buffer buf
              (should (buffer-modified-p))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(provide 'sharpener-scaffold-tests)
;;; sharpener-scaffold-tests.el ends here
