;;; install-deps.el --- Install sharpener's test dependencies -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch bootstrap that installs the third-party packages sharpener's
;; tests exercise (currently yasnippet), so that :dotnet/yasnippet tests
;; RUN rather than skip in a clean environment.  Invoked once at Docker
;; image build time, and usable locally to provision a throwaway package
;; dir for CI.
;;
;; Uses a build-local package directory (passed via
;; SHARPENER_TEST_PKGDIR, default /root/.sharpener-pkg) so it never
;; touches a developer's real ~/.emacs.d.
;;
;; Usage:
;;   emacs -Q -batch -l test/install-deps.el

;;; Code:

(require 'package)

;; Isolated package dir so we never pollute a real config.
(setq package-user-dir
      (or (getenv "SHARPENER_TEST_PKGDIR")
          (expand-file-name ".sharpener-pkg" (or (getenv "HOME") "/root"))))

(setq package-archives
      '(("gnu"   . "https://elpa.gnu.org/packages/")
        ("melpa" . "https://melpa.org/packages/")))

(package-initialize)
(package-refresh-contents)

;; The tests' third-party runtime deps. Keep in sync with the package's
;; Package-Requires (minus what ships with Emacs, like transient on 29+).
(dolist (pkg '(yasnippet web-mode))
  (unless (package-installed-p pkg)
    (message "Installing %s..." pkg)
    (package-install pkg)))

(message "sharpener test deps installed into %s" package-user-dir)

;;; install-deps.el ends here
