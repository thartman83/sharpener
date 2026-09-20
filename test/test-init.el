;;; test-init.el --- Package bootstrap for batch test runs -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by the Makefile's batch invocation (via -l) BEFORE the test
;; files, so that third-party dependencies installed by install-deps.el
;; are on the load-path.  Because the suite runs under `emacs -Q' (no
;; init), packages are not auto-initialized; this file does it explicitly
;; against the same isolated package dir install-deps.el used.
;;
;; If the dep dir doesn't exist (deps never installed), this is a no-op
;; and yasnippet-dependent tests skip as before -- so the fast path still
;; works without provisioning.

;;; Code:

(require 'package)
(setq package-user-dir
      (or (getenv "SHARPENER_TEST_PKGDIR")
          (expand-file-name ".sharpener-pkg" (or (getenv "HOME") "/root"))))
(when (file-directory-p package-user-dir)
  (package-initialize))

;;; test-init.el ends here
